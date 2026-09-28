# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Esalink::SpecSupport
private alias E = Einvoicing::SpecSupport
private alias Sim = Esalink::SpecSupport::SimulatedEsalink

private def signed_in : PartiduoUi::Browser
  S.books
  PartiduoUi::Accounts.signed_in
end

private def form(environment : String = "preproduction", password : String = Sim::PASSWORD,
                 production_url : String = "") : Hash(String, String)
  {"environment" => environment, "username" => Sim::USERNAME, "password" => password, "api_key" => Sim::API_KEY,
   "preproduction_url" => "", "production_url" => production_url, "directory_url" => "", "token_url" => ""}
end

describe "Écran de raccordement EsaLink sous /ext/ESALINK/ (ADR-005 D4)" do
  it "est montée sous le code de l'extension, avec la permission de raccordement" do
    Marten.routes.reverse("esalink:index").should eq("/ext/ESALINK/")
    Marten.routes.reverse("esalink:check").should eq("/ext/ESALINK/check")
    mount = PartiduoUi::Extensions["ESALINK"]? || raise("interface non montée")
    mount.permission.should eq(Esalink::Api::CONFIGURE)
  end

  it "n'existe pas tant que l'extension est inactive (404)" do
    E.books
    PartiduoUi::Accounts.signed_in.get("/ext/ESALINK/").status.should eq(404)
  end

  it "raccorde : identifiants refusés, puis état avec l'environnement ; secrets jamais réaffichés" do
    browser = signed_in
    html = browser.get("/ext/ESALINK/").html
    html.should contain("<h1>Plateforme agréée EsaLink")
    html.should contain("EsaLink n'est pas raccordé")
    html.should contain(%(<option value="preproduction" selected>Préproduction</option>))
    html.should contain(%(placeholder="#{Esalink::Connector::PREPRODUCTION_URL}"))
    html.should contain(%(data-esalink-deviation="token_password"))
    refused = browser.post("/ext/ESALINK/connect", form(password: "faux-secret"))
    refused.status.should eq(422)
    refused.html.should contain("Authentification refusée par la plateforme (401).")
    refused.html.should_not contain("faux-secret")
    refused.html.should contain(%(value="#{Sim::USERNAME}"))
    missing = browser.post("/ext/ESALINK/connect", form("production"))
    missing.status.should eq(422)
    missing.html.should contain("Indiquez l'adresse de production communiquée par EsaLink.")
    ok = browser.post("/ext/ESALINK/connect", form)
    ok.status.should eq(302)
    html = browser.get("/ext/ESALINK/").html
    html.should contain("EsaLink est raccordé (Préproduction).")
    html.should contain(%(data-esalink-mode="preproduction"))
    html.should contain(Esalink::Connector::PREPRODUCTION_URL)
    html.should contain("Enregistré — laissez vide pour le garder")
    html.should_not contain(Sim::PASSWORD)
    html.should_not contain(Sim::API_KEY)
    # Le mode est aussi rappelé sur les écrans d'EINV.
    browser.get("/ext/EINV/incoming").html.should contain(%(data-einv-mode="sandbox"))
    browser.get("/ext/EINV/settings").html.should contain("EsaLink — Hubtimize (API Flux XP Z12-013)")
  end

  it "teste la connexion, passe en production, puis déconnecte" do
    browser = signed_in
    browser.post("/ext/ESALINK/connect", form).status.should eq(302)
    browser.post("/ext/ESALINK/check", {} of String => String).status.should eq(302)
    browser.get("/ext/ESALINK/").html.should contain("EsaLink répond (Préproduction, #{Esalink::Connector::PREPRODUCTION_URL}).")
    S.platform.unhealthy = true
    browser.post("/ext/ESALINK/check", {} of String => String)
    browser.get("/ext/ESALINK/").html.should contain("EsaLink ne répond pas comme attendu")
    S.platform.unhealthy = false
    # Changer d'environnement exige de saisir à nouveau le mot de passe.
    again = browser.post("/ext/ESALINK/connect", form("production", "", Sim::PRODUCTION_URL))
    again.status.should eq(422)
    again.html.should contain("Environnement ou adresse modifiés : saisissez à nouveau ce secret.")
    browser.post("/ext/ESALINK/connect", form("production", Sim::PASSWORD, Sim::PRODUCTION_URL)).status.should eq(302)
    html = browser.get("/ext/ESALINK/").html
    html.should contain(%(data-esalink-mode="production"))
    html.should contain(Sim::PRODUCTION_URL)
    browser.post("/ext/ESALINK/disconnect", {} of String => String).status.should eq(302)
    html = browser.get("/ext/ESALINK/").html
    html.should contain("EsaLink est déconnecté.")
    html.should contain("ses paramètres restent enregistrés")
  end

  it "est refusée (403) sans esalink.connection.manage, avant le handler" do
    S.books
    profile = PartiduoUi::Accounts.profile("EINV seul", E::PERMISSIONS)
    PartiduoUi::Accounts.create(email: "bob@example.com", profile: nil, profile_id: profile)
    browser = PartiduoUi::Accounts.signed_in("bob@example.com")
    response = browser.get("/ext/ESALINK/")
    response.status.should eq(403)
    response.html.should_not contain("<h1>Plateforme agréée EsaLink")
    browser.post("/ext/ESALINK/connect", form).status.should eq(403)
    browser.post("/ext/ESALINK/check", {} of String => String).status.should eq(403)
    S.platform.calls.should be_empty
  end

  it "montre l'écran mais refuse d'enregistrer ou de débrancher sans einvoicing.settings.manage" do
    S.books
    S.connect
    profile = PartiduoUi::Accounts.profile("Raccordement seul", [Esalink::Api::CONFIGURE])
    PartiduoUi::Accounts.create(email: "bob@example.com", profile: nil, profile_id: profile)
    browser = PartiduoUi::Accounts.signed_in("bob@example.com")
    html = browser.get("/ext/ESALINK/").html
    html.should contain(%(data-esalink-mode="preproduction"))
    # Ni formulaire d'enregistrement ni déconnexion, mais un message.
    html.should contain("data-esalink-no-link")
    html.should contain("exige aussi la permission de paramétrer la facturation électronique")
    html.should_not contain(%(action="/ext/ESALINK/connect"))
    html.should_not contain("data-esalink-disconnect")
    html.should contain("data-esalink-check")
    browser.post("/ext/ESALINK/check", {} of String => String).status.should eq(302)
    calls = S.platform.calls.size
    browser.post("/ext/ESALINK/connect", form).status.should eq(403)
    browser.post("/ext/ESALINK/disconnect", {} of String => String).status.should eq(403)
    S.platform.calls.size.should eq(calls)
    Einvoicing::Connection.filter(adapter: "ESALINK").first!.active.should be_true
  end

  it "signale le test ou la déconnexion sans raccordement, et renvoie les GET vers l'écran" do
    browser = signed_in
    browser.post("/ext/ESALINK/check", {} of String => String).status.should eq(302)
    browser.get("/ext/ESALINK/").html.should contain("EsaLink n'est pas la plateforme raccordée.")
    browser.post("/ext/ESALINK/disconnect", {} of String => String).status.should eq(302)
    browser.get("/ext/ESALINK/").html.should contain("EsaLink n'est pas la plateforme raccordée.")
    %w[connect check disconnect].each do |action|
      response = browser.get("/ext/ESALINK/#{action}")
      response.status.should eq(302)
      response.headers["Location"].should eq("/ext/ESALINK/")
    end
    S.platform.calls.should be_empty
  end

  it "ne renvoie jamais les secrets saisis, même sur un formulaire refusé" do
    browser = signed_in
    refused = browser.post("/ext/ESALINK/connect", form("demo", "secret-saisi-9"))
    refused.status.should eq(422)
    refused.html.should_not contain("secret-saisi-9")
    refused.html.should_not contain(Sim::API_KEY)
  end

  it "se traduit en anglais et en néerlandais" do
    browser = signed_in
    {
      "en" => {"EsaLink accredited platform", "Test and connect", "Password"},
      "nl" => {"Erkend platform EsaLink", "Testen en koppelen", "Wachtwoord"},
      "fr" => {"Plateforme agréée EsaLink", "Tester et raccorder", "Mot de passe"},
    }.each do |locale, texts|
      browser.post("/language", {"locale" => locale, "next" => "/ext/ESALINK/"})
      html = browser.get("/ext/ESALINK/").html
      texts.each { |text| html.should contain(text) }
      unless locale == "fr"
        html.should_not contain("Plateforme agréée EsaLink")
        html.should_not contain("Tester et raccorder")
      end
    end
    I18n.locale = "fr"
  end
end
