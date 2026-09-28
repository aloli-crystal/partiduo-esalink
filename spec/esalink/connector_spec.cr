# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Esalink::SpecSupport
private alias Api = Esalink::Api
private alias Sim = Esalink::SpecSupport::SimulatedEsalink
private alias Connections = Einvoicing::Connections
private alias Http = Einvoicing::Http

# Adaptateur dont les points d'extension protégés sont rendus lisibles.
private class ExposedConnector < Esalink::Connector
  def url_of(path : String) : String
    flow_url(path)
  end

  def headers_of : Hash(String, String)
    platform_headers
  end

  def address_of(url : String, request_id : String) : String
    request_url(url, request_id)
  end

  def accept_of : String
    download_accept
  end

  def limit_of : Int32
    page_limit
  end

  def more?(body : String, count : Int32) : Bool
    more_without_cursor?(JSON.parse(body), Array.new(count) { JSON::Any.new(nil) })
  end

  def token_of : String
    authenticate
  end
end

# Adaptateur aux petites pages, pour déclencher la relecture complète.
private class SmallPages < Esalink::Connector
  protected def page_limit : Int32
    2
  end
end

private def settings(values : Hash(String, String) = {} of String => String,
                     secrets : Hash(String, String) = {"password" => Sim::PASSWORD}) : Connections::Settings
  plain = {"environment" => "preproduction", "username" => Sim::USERNAME}.merge(values)
  Connections::Settings.new("ESALINK", plain, secrets)
end

private def exposed(values : Hash(String, String) = {} of String => String,
                    secrets : Hash(String, String) = {"password" => Sim::PASSWORD}) : ExposedConnector
  ExposedConnector.new(settings(values, secrets))
end

# Transport qui répond lui-même à `POST /token` (réponse fixée par le
# spec) et transmet le reste à EsaLink simulée.
private class TokenStub < Http::Transport
  getter calls = [] of Http::Request

  def initialize(@next : Http::Transport, @status : Int32, @body : String)
  end

  def exec(request : Http::Request) : Http::Response
    @calls << request
    return @next.exec(request) unless request.url.ends_with?("/token")
    Http::Response.new(@status, {"content-type" => "application/json"}, @body.to_slice)
  end
end

describe "Adaptateur EsaLink : points d'extension de l'adaptateur XP Z12-013" do
  it "calcule l'adresse d'orchestration selon l'environnement, terminée par /" do
    Esalink::Connector.base_url(settings).should eq(Esalink::Connector::PREPRODUCTION_URL)
    Esalink::Connector.base_url(settings({"preproduction_url" => "https://ppd.example.test/api/v1"}))
      .should eq("https://ppd.example.test/api/v1/")
    Esalink::Connector.base_url(settings({"environment" => "production", "production_url" => Sim::PRODUCTION_URL,
                                          "preproduction_url" => "https://ppd.example.test/"})).should eq(Sim::PRODUCTION_URL)
    Esalink::Connector.base_url(settings({"environment" => "production", "production_url" => "https://prod.test/v1"}))
      .should eq("https://prod.test/v1/")
  end

  it "refuse la production sans adresse (jamais de repli silencieux sur la préproduction)" do
    error = expect_raises(Einvoicing::ConnectorError) do
      Esalink::Connector.base_url(settings({"environment" => "production"}))
    end
    error.key.should eq("esalink.errors.transport.no_production_url")
    error.localized.should_not be_empty
    error.localized.should_not eq("esalink.errors.transport.no_production_url")
  end

  it "ne connaît que deux modes : production, sinon bac à sable" do
    exposed.mode.should eq("sandbox")
    exposed({"environment" => "production", "production_url" => Sim::PRODUCTION_URL}).mode.should eq("production")
    exposed({"environment" => "inconnu"}).mode.should eq("sandbox")
  end

  it "place les chemins /v1/… de l'API Flux sous l'adresse d'orchestration, qui porte déjà la version" do
    connector = exposed
    connector.url_of("/v1/flows").should eq("#{Esalink::Connector::PREPRODUCTION_URL}flows")
    connector.url_of("/v1/flows/search").should eq("#{Esalink::Connector::PREPRODUCTION_URL}flows/search")
    connector.url_of("/v1/healthcheck").should eq("#{Esalink::Connector::PREPRODUCTION_URL}healthcheck")
    exposed({"preproduction_url" => "https://ppd.example.test/o/v1"}).url_of("/v1/flows/F-1?docType=Original")
      .should eq("https://ppd.example.test/o/v1/flows/F-1?docType=Original")
  end

  it "ajoute Request-Id en paramètre d'adresse, avec ? ou & selon l'adresse" do
    connector = exposed
    connector.address_of("https://h.test/flows", "abc-1").should eq("https://h.test/flows?Request-Id=abc-1")
    connector.address_of("https://h.test/flows/F?docType=Original", "abc-2")
      .should eq("https://h.test/flows/F?docType=Original&Request-Id=abc-2")
  end

  it "n'envoie la clé hubtimize-api-key que si elle est renseignée, jamais Organization-Id" do
    exposed.headers_of.should be_empty
    headers = exposed(secrets: {"password" => Sim::PASSWORD, "api_key" => "k-1"}).headers_of
    headers.should eq({"hubtimize-api-key" => "k-1"})
    exposed({"organization_id" => "ORG"}).headers_of.has_key?("Organization-Id").should be_false
  end

  it "télécharge en application/octet-stream et demande des pages larges" do
    exposed.accept_of.should eq("application/octet-stream")
    exposed.limit_of.should eq(Esalink::Connector::PAGE_LIMIT)
    Esalink::Connector::PAGE_LIMIT.should be > Einvoicing::Connectors::Afnor::LIMIT
  end

  it "sans nextCursor, juge qu'il reste des flux d'après total (nombre ou texte), sinon d'après une page pleine" do
    connector = exposed
    connector.more?(%({"total": 7}), 3).should be_true
    connector.more?(%({"total": 3}), 3).should be_false
    connector.more?(%({"total": "10"}), 3).should be_true
    connector.more?(%({"total": "3"}), 3).should be_false
    connector.more?(%({}), Esalink::Connector::PAGE_LIMIT).should be_true
    connector.more?(%({}), Esalink::Connector::PAGE_LIMIT - 1).should be_false
    connector.more?(%({"total": "illisible"}), 1).should be_false
  end

  it "liste sept écarts à la norme, tous traduits en fr, en et nl" do
    Esalink::Connector::DEVIATIONS.size.should eq(7)
    Esalink::Connector::DEVIATIONS.uniq.size.should eq(7)
    Partiduo::LOCALES.each do |locale|
      I18n.with_locale(locale) do
        Esalink::Connector::DEVIATIONS.each do |code|
          I18n.t("esalink.deviations.#{code}").should_not start_with("esalink.")
        end
      end
    end
  end
end

describe "Adaptateur EsaLink : jeton POST /token" do
  it "rend le jeton sans le conserver quand le raccordement n'est pas enregistré (essai)" do
    connector = exposed(secrets: {"password" => Sim::PASSWORD, "api_key" => Sim::API_KEY})
    connector.token_of.should eq("esl-1")
    connector.token_of.should eq("esl-2")
    connector.settings.access_token.should be_nil
    body = JSON.parse(String.new(S.platform.calls.first.body || Bytes.empty))
    body.as_h.keys.sort!.should eq(%w[password username])
  end

  it "refuse une réponse sans access_token" do
    S.books
    stub = TokenStub.new(S.platform, 200, %({"token_type": "Bearer"}))
    Http.transport = stub
    result = Api.connect(S.admin, S.input)
    result.errors.map(&.key).should eq(["esalink.errors.connection.failed"])
    I18n.t(result.errors.first.key, result.errors.first.params).should contain("access_token")
    Einvoicing::Connection.filter(adapter: "ESALINK").exists?.should be_false
  end

  it "refuse un access_token vide" do
    S.books
    Http.transport = TokenStub.new(S.platform, 200, %({"access_token": "", "expires_in": 60}))
    Api.connect(S.admin, S.input).failure?.should be_true
  end

  it "signale une réponse illisible de /token sans divulguer le mot de passe" do
    S.books
    Http.transport = TokenStub.new(S.platform, 200, "<html>#{Sim::PASSWORD}</html>")
    result = Api.connect(S.admin, S.input)
    result.failure?.should be_true
    I18n.t(result.errors.first.key, result.errors.first.params).should_not contain(Sim::PASSWORD)
    Einvoicing::Connection.filter(adapter: "ESALINK").exists?.should be_false
  end

  it "signale une panne de /token (500) comme un refus d'authentification" do
    S.books
    Http.transport = TokenStub.new(S.platform, 500, %({"message": "boom"}))
    result = Api.connect(S.admin, S.input)
    message = I18n.t(result.errors.first.key, result.errors.first.params)
    message.should contain("500")
    message.should_not contain(Sim::PASSWORD)
  end

  it "accepte expires_in en texte" do
    S.books
    S.connect
    # Jeton de 120 secondes rendu en texte par un proxy : lu comme un nombre.
    Http.transport = TokenStub.new(S.platform, 200, %({"access_token": "esl-texte", "expires_in": "120"}))
    S.platform.tokens << "esl-texte"
    S.platform.token_hosts["esl-texte"] = Sim::PREPRODUCTION_HOST
    Api.check(S.admin).success?.should be_true
    row = Einvoicing::Connection.filter(adapter: "ESALINK").first!
    (row.access_token_expires_at || raise "expiration absente").should be_close(Time.utc + 120.seconds, 30.seconds)
  end

  it "ne transmet jamais un jeton de préproduction à la production" do
    S.books
    S.connect
    Api.check(S.admin).value!
    S.connect("production")
    Api.check(S.admin).value!
    S.connect
    Api.check(S.admin).value!
    S.platform.calls.select(&.url.includes?("/healthcheck")).each do |request|
      bearer = request.headers["Authorization"].lchop("Bearer ")
      S.platform.token_hosts[bearer].should eq(URI.parse(request.url).host)
    end
    # Aucun refus 401 : le jeton est oublié à chaque nouvel enregistrement.
    S.platform.calls.count(&.url.includes?("/healthcheck")).should eq(6)
  end
end

describe "Adaptateur EsaLink : recherche sans nextCursor, ordre non garanti (D-ESL-002)" do
  %w[desc shuffled].each do |order|
    it "relit toute la recherche (limit = total) quand EsaLink rend les flux dans l'ordre #{order}" do
      S.platform.page_size = 1000
      S.platform.result_order = order
      5.times { |index| S.platform.deliver(Einvoicing::SpecSupport.ubl_invoice("FM-#{index}"), "f#{index}.xml", "UBL") }
      connector = SmallPages.new(settings(secrets: {"password" => Sim::PASSWORD, "api_key" => Sim::API_KEY}))
      page = connector.fetch_incoming(nil)
      page.has_more.should be_false
      page.items.map(&.platform_ref).should eq(S.platform.flows.sort_by(&.updated_at).map(&.id))
      searches = S.platform.calls.select(&.url.includes?("/flows/search"))
      searches.map { |request| JSON.parse(String.new(request.body || Bytes.empty))["limit"].as_i }.should eq([2, 5])
    end
  end
end

describe "Adaptateur EsaLink : adresse d'authentification" do
  it "demande le jeton à l'adresse de l'API suivie de token, ou à token_url si elle est renseignée" do
    connector = exposed(secrets: {"password" => Sim::PASSWORD, "api_key" => Sim::API_KEY})
    connector.token_url.should eq("#{Esalink::Connector::PREPRODUCTION_URL}token")
    connector.token_of
    S.platform.calls.last.url.should eq("#{Esalink::Connector::PREPRODUCTION_URL}token")
    separate = "#{Sim::PRODUCTION_URL}token"
    other = exposed({"token_url" => separate}, {"password" => Sim::PASSWORD, "api_key" => Sim::API_KEY})
    other.token_url.should eq(separate)
    other.token_of
    S.platform.calls.last.url.should eq(separate)
  end
end
