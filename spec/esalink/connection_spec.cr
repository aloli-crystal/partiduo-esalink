# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Esalink::SpecSupport
private alias E = Einvoicing::SpecSupport
private alias Api = Esalink::Api
private alias EApi = Einvoicing::Api
private alias Sim = Esalink::SpecSupport::SimulatedEsalink

private def token_calls : Array(Einvoicing::Http::Request)
  S.platform.calls.select(&.url.ends_with?("/token"))
end

describe "Raccordement à EsaLink (ADR-004 D2)" do
  it "s'enregistre auprès d'EINV : dossiers français, identifiant, mot de passe, environnement et adresses" do
    S.books
    adapter = EApi.adapters(S.admin).find! { |item| item.code == "ESALINK" }
    adapter.available.should be_true
    adapter.label_key.should eq("esalink.adapter")
    adapter.fields.map { |field| {field.name, field.secret, field.required} }.should eq([
      {"environment", false, true}, {"username", false, true}, {"password", true, true}, {"api_key", true, false},
      {"preproduction_url", false, false}, {"production_url", false, false}, {"directory_url", false, false},
    ])
    I18n.t("einvoicing.fields.password").should eq("Mot de passe")
    I18n.t("einvoicing.modes.preproduction").should eq("Préproduction")
  end

  it "n'est pas proposée à un dossier belge" do
    S.books("be")
    EApi.adapters(S.admin).find! { |item| item.code == "ESALINK" }.available.should be_false
    result = Api.connect(S.admin, S.input)
    result.errors.map(&.key).should contain("einvoicing.errors.connection.adapter.regime")
    S.platform.calls.should be_empty
  end

  it "essaie jeton et santé avant d'enregistrer ; secrets chiffrés, jamais réaffichés" do
    S.books
    view = S.connect
    {view.connected, view.environment, view.mode, view.username}.should eq({true, "preproduction", "sandbox", Sim::USERNAME})
    {view.password_stored, view.api_key_stored}.should eq({true, true})
    view.effective_url.should eq(Esalink::Connector::PREPRODUCTION_URL)
    # Jeton demandé en JSON, clé d'API en en-tête, puis contrôle de santé.
    token = token_calls.first
    token.url.should eq("https://ppd.hubtimize.fr/api/orchestrator/v1/token")
    token.headers["Content-Type"].should eq("application/json")
    token.headers["hubtimize-api-key"].should eq(Sim::API_KEY)
    JSON.parse(String.new(token.body || Bytes.empty))["username"].should eq(Sim::USERNAME)
    health = S.platform.calls.find!(&.url.includes?("/healthcheck"))
    health.url.should eq("https://ppd.hubtimize.fr/api/orchestrator/v1/healthcheck?Request-Id=#{health.headers["Request-Id"]}")
    # Adaptateur actif d'EINV ; secrets chiffrés, jeton d'essai non conservé.
    connection = EApi.connection(S.admin) || raise "raccordement absent"
    {connection.adapter, connection.mode}.should eq({"ESALINK", "sandbox"})
    row = Einvoicing::Connection.filter(adapter: "ESALINK").first!
    {row.secrets.to_s, row.settings.to_json}.each do |text|
      text.should_not contain(Sim::PASSWORD)
      text.should_not contain(Sim::API_KEY)
    end
    row.access_token.to_s.should be_empty
    connection.fields.find!(&.name.==("password")).value.should be_empty
  end

  it "refuse de mauvais identifiants sans rien enregistrer ni afficher le mot de passe" do
    S.books
    result = Api.connect(S.admin, S.input(password: "faux-mot-de-passe"))
    result.failure?.should be_true
    error = result.errors.first
    error.key.should eq("esalink.errors.connection.failed")
    message = I18n.t(error.key, error.params)
    message.should contain("401")
    message.should_not contain("faux-mot-de-passe")
    EApi.connection(S.admin).should be_nil
    Einvoicing::Connection.filter(adapter: "ESALINK").exists?.should be_false
  end

  it "contrôle les champs : obligatoires, HTTPS, environnement, adresse de production" do
    S.books
    blank = Api.connect(S.admin, Api::ConnectionInput.new(environment: "demo", username: "", preproduction_url: "http://ppd.test"))
    blank.errors.map { |error| {error.field, error.key} }.should eq([
      {"environment", "einvoicing.errors.connection.field.choice"},
      {"username", "einvoicing.errors.connection.field.blank"},
      {"password", "einvoicing.errors.connection.field.blank"},
      {"preproduction_url", "einvoicing.errors.connection.field.https"},
    ])
    production = Api.connect(S.admin, S.input("production"))
    production.errors.map { |error| {error.field, error.key} }
      .should eq([{"production_url", "esalink.errors.connection.production_url"}])
    S.platform.calls.should be_empty
  end

  it "se raccorde en production à l'adresse saisie ; le mode est affiché partout" do
    S.books
    view = S.connect("production")
    {view.environment, view.mode, view.effective_url}.should eq({"production", "production", Sim::PRODUCTION_URL})
    S.platform.calls.map { |request| URI.parse(request.url).host }.uniq!.should eq([Sim::PRODUCTION_HOST])
    EApi.connection(S.admin).try(&.mode).should eq("production")
    I18n.t(Api.status(S.admin).environment_key).should eq("Production")
  end

  it "garde le mot de passe et la clé enregistrés quand ils sont laissés vides" do
    S.books
    S.connect
    view = Api.connect(S.admin, S.input(password: "", api_key: "")).value!
    {view.password_stored, view.api_key_stored}.should eq({true, true})
    token_calls.last.headers["hubtimize-api-key"].should eq(Sim::API_KEY)
  end

  it "fonctionne sans clé d'API si EsaLink n'en exige pas" do
    S.books
    S.platform.api_key = nil
    view = Api.connect(S.admin, S.input(api_key: "")).value!
    view.api_key_stored.should be_false
    S.platform.calls.none?(&.headers.has_key?("hubtimize-api-key")).should be_true
  end

  it "teste la connexion : jeton conservé chiffré puis réutilisé ; santé en panne signalée" do
    S.books
    S.connect
    before = S.platform.token_count
    check = Api.check(S.admin).value!
    {check.mode, check.url}.should eq({"sandbox", Esalink::Connector::PREPRODUCTION_URL})
    I18n.t(check.mode_key).should eq("Préproduction")
    row = Einvoicing::Connection.filter(adapter: "ESALINK").first!
    row.access_token.to_s.should start_with("v1:")
    (row.access_token_expires_at || raise "expiration absente").should be_close(Time.utc + 1.hour, 1.minute)
    Api.check(S.admin).success?.should be_true
    S.platform.token_count.should eq(before + 1)
    S.platform.unhealthy = true
    failed = Api.check(S.admin)
    failed.errors.map(&.key).should eq(["esalink.errors.connection.failed"])
  end

  it "renouvelle le jeton à son expiration (refus 401) et sans expires_in, avec une durée prudente" do
    S.books
    S.connect
    Api.check(S.admin).value!
    count = S.platform.token_count
    S.platform.expire_tokens
    Api.check(S.admin).success?.should be_true
    S.platform.token_count.should eq(count + 1)
    # Jeton rendu sans durée : quinze minutes.
    S.platform.expires_in = nil
    S.platform.expire_tokens
    Api.check(S.admin).success?.should be_true
    row = Einvoicing::Connection.filter(adapter: "ESALINK").first!
    (row.access_token_expires_at || raise "expiration absente").should be_close(Time.utc + 15.minutes, 1.minute)
    # Jeton expiré selon sa date : redemandé sans attendre le refus.
    Einvoicing::Connection.filter(id: row.id).update(access_token_expires_at: Time.utc - 1.minute)
    count = S.platform.token_count
    Api.check(S.admin).success?.should be_true
    S.platform.token_count.should eq(count + 1)
  end

  it "déconnecte en gardant les paramètres ; test et déconnexion refusés hors raccordement" do
    S.books
    Api.check(S.admin).errors.map(&.key).should eq(["esalink.errors.connection.missing"])
    S.connect
    Api.disconnect(S.admin).success?.should be_true
    view = Api.status(S.admin)
    {view.connected, view.configured, view.username}.should eq({false, true, Sim::USERNAME})
    EApi.connection(S.admin).should be_nil
    Api.check(S.admin).errors.map(&.key).should eq(["esalink.errors.connection.missing"])
    Api.disconnect(S.admin).errors.map(&.key).should eq(["esalink.errors.connection.missing"])
    # Une autre plateforme raccordée est signalée.
    E.connect_afnor
    Api.status(S.admin).other_adapter.should eq("AFNOR")
  end

  it "exige ses permissions et le module actif" do
    E.books
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.status(S.admin) }
    Partiduo::Api::Modules.activate(S::SYSTEM, "ESALINK").value!
    reader = Partiduo::Api::Actor.user(2_i64, [Api::CONFIGURE])
    Api.status(reader).connected.should be_false
    expect_raises(Partiduo::Api::Forbidden) { Api.connect(reader, S.input) }
    expect_raises(Partiduo::Api::Forbidden) { Api.status(Partiduo::Api::Actor.user(2_i64, [EApi::CONFIGURE])) }
    S.platform.calls.should be_empty
  end
end
