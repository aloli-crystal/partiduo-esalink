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
   "preproduction_url" => "", "production_url" => production_url, "directory_url" => ""}
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
    browser.post("/ext/ESALINK/connect", form("production", "", Sim::PRODUCTION_URL)).status.should eq(302)
    html = browser.get("/ext/ESALINK/").html
    html.should contain(%(data-esalink-mode="production"))
    html.should contain(Sim::PRODUCTION_URL)
    browser.post("/ext/ESALINK/disconnect", {} of String => String).status.should eq(302)
    html = browser.get("/ext/ESALINK/").html
    html.should contain("EsaLink est déconnecté.")
    html.should contain("ses paramètres restent enregistrés")
  end
end
