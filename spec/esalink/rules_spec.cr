# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Esalink::SpecSupport
private alias E = Einvoicing::SpecSupport
private alias Api = Esalink::Api
private alias EApi = Einvoicing::Api
private alias Sim = Esalink::SpecSupport::SimulatedEsalink
private alias Mods = Partiduo::Api::Modules

private def row : Einvoicing::Connection
  Einvoicing::Connection.filter(adapter: "ESALINK").first!
end

private def actor(permissions : Array(String)) : Partiduo::Api::Actor
  Partiduo::Api::Actor.user(E.admin.user_id || 1_i64, permissions, level: 3)
end

# Insertion SQL directe : c'est la base, pas le modèle, qui doit refuser.
private def insert_connection(adapter : String, active : Bool) : Nil
  Marten::DB::Connection.default.open do |db|
    db.exec("INSERT INTO einvoicing_connection (adapter, active, settings, secrets, access_token, refresh_token, " \
            "last_error, created_at, updated_at) VALUES ($1, $2, '{}', '', '', '', '', now(), now())", adapter, active)
  end
end

private def keys(result) : Array(String)
  result.errors.map(&.key)
end

describe "EsaLink : état avant tout raccordement" do
  it "rend les valeurs par défaut sans appeler EsaLink" do
    S.books
    view = Api.status(S.admin)
    {view.connected, view.configured, view.other_adapter}.should eq({false, false, nil})
    {view.environment, view.mode, view.username}.should eq({"preproduction", "sandbox", ""})
    {view.password_stored, view.api_key_stored}.should eq({false, false})
    view.effective_url.should eq(Esalink::Connector::PREPRODUCTION_URL)
    {view.last_sync_at, view.last_error}.should eq({nil, ""})
    I18n.t(view.environment_key).should eq("Préproduction")
    S.platform.calls.should be_empty
  end

  it "reprend l'adresse de préproduction saisie (sans / final) comme adresse effective" do
    S.books
    input = Api::ConnectionInput.new(environment: "preproduction", username: Sim::USERNAME, password: Sim::PASSWORD,
      api_key: Sim::API_KEY, preproduction_url: " https://#{Sim::PREPRODUCTION_HOST}/api/orchestrator/v1 ")
    view = Api.connect(S.admin, input).value!
    view.preproduction_url.should eq("https://#{Sim::PREPRODUCTION_HOST}/api/orchestrator/v1")
    view.effective_url.should eq(Esalink::Connector::PREPRODUCTION_URL)
  end
end

describe "EsaLink : raccordement et intégrité en base" do
  it "ne garde qu'une ligne ESALINK, quel que soit le nombre d'enregistrements" do
    S.books
    3.times { S.connect }
    Einvoicing::Connection.filter(adapter: "ESALINK").count.should eq(1)
    Einvoicing::Connection.filter(active: true).count.should eq(1)
  end

  it "refuse en base une seconde ligne ESALINK (adaptateur unique)" do
    S.books
    S.connect
    expect_raises(Exception, /unique|duplicate/i) do
      insert_connection("ESALINK", false)
    end
    Einvoicing::Connection.filter(adapter: "ESALINK").count.should eq(1)
  end

  it "refuse en base deux raccordements actifs à la fois (index unique partiel)" do
    S.books
    S.connect
    expect_raises(Exception, /unique|duplicate/i) do
      insert_connection("AFNOR", true)
    end
    Einvoicing::Connection.filter(active: true).count.should eq(1)
  end

  it "remplace la plateforme active : EsaLink débranche AFNOR, et inversement" do
    S.books
    E.connect_afnor
    Api.status(S.admin).other_adapter.should eq("AFNOR")
    S.connect
    Einvoicing::Connection.filter(adapter: "AFNOR").first!.active.should be_false
    EApi.connection(S.admin).try(&.adapter).should eq("ESALINK")
    Api.status(S.admin).other_adapter.should be_nil
    E.connect_afnor
    row.active.should be_false
    view = Api.status(S.admin)
    {view.connected, view.configured, view.other_adapter}.should eq({false, true, "AFNOR"})
    # EsaLink débranché : ni test ni déconnexion, qui débrancherait AFNOR.
    keys(Api.check(S.admin)).should eq(["esalink.errors.connection.missing"])
    keys(Api.disconnect(S.admin)).should eq(["esalink.errors.connection.missing"])
    EApi.connection(S.admin).try(&.adapter).should eq("AFNOR")
  end

  it "garde intacts les paramètres enregistrés quand un nouvel essai échoue" do
    S.books
    S.connect
    before = {row.settings.to_json, row.secrets.to_s}
    changed = Api::ConnectionInput.new(environment: "preproduction", username: "autre-identifiant")
    keys(Api.connect(S.admin, changed)).should eq(["esalink.errors.connection.failed"])
    wrong_key = Api.connect(S.admin, S.input(api_key: "mauvaise-cle"))
    I18n.t(wrong_key.errors.first.key, wrong_key.errors.first.params).should contain("403")
    {row.settings.to_json, row.secrets.to_s}.should eq(before)
    Api.status(S.admin).username.should eq(Sim::USERNAME)
    Api.check(S.admin).success?.should be_true
  end

  it "essaie les secrets enregistrés quand ils sont laissés vides, sans en garder de jeton" do
    S.books
    S.connect
    Api.check(S.admin).value!
    Api.connect(S.admin, S.input(password: "", api_key: "")).value!
    body = JSON.parse(String.new(S.platform.calls.reverse_each.find!(&.url.ends_with?("/token")).body || Bytes.empty))
    body["password"].should eq(Sim::PASSWORD)
    row.access_token.to_s.should be_empty
    row.access_token_expires_at.should be_nil
  end

  it "rogne les espaces saisis autour des valeurs" do
    S.books
    input = Api::ConnectionInput.new(environment: " preproduction ", username: " #{Sim::USERNAME} ",
      password: " #{Sim::PASSWORD} ", api_key: " #{Sim::API_KEY} ")
    view = Api.connect(S.admin, input).value!
    {view.environment, view.username}.should eq({"preproduction", Sim::USERNAME})
    Api.check(S.admin).success?.should be_true
  end

  it "refuse une adresse de production non HTTPS et des valeurs trop longues, sans appeler EsaLink" do
    S.books
    http = Api.connect(S.admin, S.input("production", production_url: "http://#{Sim::PRODUCTION_HOST}/api/orchestrator/v1/"))
    http.errors.map { |error| {error.field, error.key} }.should eq([{"production_url", "einvoicing.errors.connection.field.https"}])
    long = Api.connect(S.admin, Api::ConnectionInput.new(environment: "preproduction", username: "u" * 2001,
      password: Sim::PASSWORD))
    long.errors.map { |error| {error.field, error.key} }.should eq([{"username", "einvoicing.errors.connection.field.too_long"}])
    S.platform.calls.should be_empty
  end

  it "déconnecte en oubliant le jeton, puis se raccorde de nouveau sans ressaisir les secrets" do
    S.books
    S.connect
    Api.check(S.admin).value!
    Api.disconnect(S.admin).success?.should be_true
    {row.active, row.access_token.to_s}.should eq({false, ""})
    view = Api.connect(S.admin, S.input(password: "", api_key: "")).value!
    view.connected.should be_true
  end
end

describe "EsaLink : secrets et adresses (D-ESL-004)" do
  it "exige de saisir à nouveau les secrets quand l'environnement ou une adresse change, sans rien envoyer" do
    S.books
    S.connect
    before = {row.settings.to_json, row.secrets.to_s}
    calls = S.platform.calls.size
    reentry = [{"password", "esalink.errors.connection.secret_reentry"}, {"api_key", "esalink.errors.connection.secret_reentry"}]
    {
      Api::ConnectionInput.new(environment: "production", username: Sim::USERNAME, production_url: Sim::PRODUCTION_URL),
      Api::ConnectionInput.new(environment: "preproduction", username: Sim::USERNAME, preproduction_url: "https://pirate.test/"),
      Api::ConnectionInput.new(environment: "preproduction", username: Sim::USERNAME, directory_url: "https://pirate.test/annuaire"),
      Api::ConnectionInput.new(environment: "preproduction", username: Sim::USERNAME, token_url: "https://pirate.test/token"),
    }.each do |input|
      Api.connect(S.admin, input).errors.map { |error| {error.field, error.key} }.should eq(reentry)
    end
    S.platform.calls.size.should eq(calls)
    {row.settings.to_json, row.secrets.to_s}.should eq(before)
    # Mot de passe saisi, clé laissée vide : seule la clé est redemandée.
    partial = Api.connect(S.admin, S.input("production", api_key: "", production_url: Sim::PRODUCTION_URL))
    partial.errors.map { |error| {error.field, error.key} }.should eq([reentry[1]])
    # Tout saisi à nouveau : raccordé en production.
    Api.connect(S.admin, S.input("production", production_url: Sim::PRODUCTION_URL)).value!.environment.should eq("production")
    I18n.t("esalink.errors.connection.secret_reentry").should eq("Environnement ou adresse modifiés : saisissez à nouveau ce secret.")
  end

  it "l'écran générique d'EINV exige aussi les secrets pour une adresse nouvelle" do
    S.books
    S.connect
    values = S.input.values.merge({"password" => "", "api_key" => "", "preproduction_url" => "https://pirate.test/"})
    result = EApi.configure(E.admin, EApi::ConnectionInput.new("ESALINK", values))
    result.errors.map { |error| {error.field, error.key} }.should eq([
      {"password", "einvoicing.errors.connection.field.secret_reentry"},
      {"api_key", "einvoicing.errors.connection.field.secret_reentry"},
    ])
  end

  it "rend can_link selon einvoicing.settings.manage" do
    S.books
    Api.status(S.admin).can_link.should be_true
    Api.status(actor([Api::CONFIGURE])).can_link.should be_false
  end
end

describe "EsaLink : permissions" do
  it "sépare l'écran (esalink.connection.manage) de l'enregistrement (plus einvoicing.settings.manage)" do
    S.books
    S.connect
    screen_only = actor([Api::CONFIGURE])
    Api.status(screen_only).connected.should be_true
    Api.check(screen_only).success?.should be_true
    calls = S.platform.calls.size
    expect_raises(Partiduo::Api::Forbidden) { Api.connect(screen_only, S.input) }
    expect_raises(Partiduo::Api::Forbidden) { Api.disconnect(screen_only) }
    S.platform.calls.size.should eq(calls)
    row.active.should be_true
  end

  it "refuse tout à qui n'a que la permission d'EINV" do
    S.books
    S.connect
    einv_only = actor(E::PERMISSIONS)
    expect_raises(Partiduo::Api::Forbidden) { Api.status(einv_only) }
    expect_raises(Partiduo::Api::Forbidden) { Api.check(einv_only) }
    expect_raises(Partiduo::Api::Forbidden) { Api.connect(einv_only, S.input) }
    expect_raises(Partiduo::Api::Forbidden) { Api.disconnect(einv_only) }
    row.active.should be_true
  end

  it "refuse l'anonyme" do
    S.books
    expect_raises(Partiduo::Api::AccessDenied) { Api.status(Partiduo::Api::Actor.anonymous) }
  end
end

describe "EsaLink : activation (ModuleDisabled, dépendance à EINV)" do
  it "lève ModuleDisabled sur tout le contrat quand l'extension est inactive, même raccordée" do
    S.books
    S.connect
    Mods.deactivate(S::SYSTEM, "ESALINK").value!
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.status(S.admin) }
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.check(S.admin) }
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.connect(S.admin, S.input) }
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.disconnect(S.admin) }
    # Données conservées : le raccordement reste en base.
    row.active.should be_true
    Mods.activate(S::SYSTEM, "ESALINK").value!
    Api.status(S.admin).connected.should be_true
  end

  it "exige EINV : pas d'activation sans lui, et EINV ne se désactive pas sous ESALINK" do
    E.books
    Mods.deactivate(S::SYSTEM, "EINV").value!
    result = Mods.activate(S::SYSTEM, "ESALINK")
    keys(result).should eq(["modules.errors.activation.missing_dependency"])
    Mods.activate(S::SYSTEM, "EINV").value!
    Mods.activate(S::SYSTEM, "ESALINK").value!
    keys(Mods.deactivate(S::SYSTEM, "EINV")).should eq(["modules.errors.activation.required_by"])
  end

  it "déclare son manifeste : dépendance, permission, menu sous Paramètres" do
    manifest = Partiduo::Modules["ESALINK"]
    manifest.permissions.should eq(["esalink.connection.manage"])
    manifest.depends_on.should eq(["EINV"])
    menu = manifest.menus.find! { |entry| entry.code == "ESALINK" }
    {menu.parent, menu.permission}.should eq({"SETTINGS", "esalink.connection.manage"})
  end
end

describe "EsaLink : annuaire par l'adaptateur XP Z12-013" do
  it "cherche dans l'API Annuaire avec la clé d'API et le Request-Id en paramètre" do
    S.books
    input = Api::ConnectionInput.new(environment: "preproduction", username: Sim::USERNAME, password: Sim::PASSWORD,
      api_key: Sim::API_KEY, directory_url: "https://pa.test/afnor-directory")
    Api.connect(S.admin, input).value!
    S.platform.directory << JSON.parse({"addressingIdentifier" => E::CUSTOMER_SIREN, "siren" => E::CUSTOMER_SIREN,
                                        "legalUnit" => {"businessName" => "Atelier Morel SAS"}}.to_json).as_h
    entries = EApi.lookup(E.admin, E::CUSTOMER_SIREN).value!
    entries.map(&.name).should eq(["Atelier Morel SAS"])
    request = S.platform.requests.find!(&.url.includes?("directory-line/search"))
    request.headers["hubtimize-api-key"].should eq(Sim::API_KEY)
    URI.parse(request.url).query_params["Request-Id"].should eq(request.headers["Request-Id"])
  end

  it "signale l'annuaire non proposé sans adresse d'annuaire" do
    S.books
    S.connect
    keys(EApi.lookup(E.admin, E::CUSTOMER_SIREN)).should eq(["einvoicing.errors.directory.unsupported"])
  end
end
