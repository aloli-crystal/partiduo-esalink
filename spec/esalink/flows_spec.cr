# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Esalink::SpecSupport
private alias E = Einvoicing::SpecSupport
private alias EApi = Einvoicing::Api
private alias Inv = Partiduo::Api::Invoicing

private def ready : Nil
  S.books
  S.connect
end

private def flow_calls(suffix : String) : Array(Einvoicing::Http::Request)
  S.platform.calls.select { |request| URI.parse(request.url).path.ends_with?(suffix) }
end

describe "Flux EsaLink par l'adaptateur XP Z12-013 d'EINV (ADR-004 D2)" do
  it "transmet le Factur-X de la Facturation par POST /flows ; « Déposée » (200) remonte" do
    ready
    invoice = E.issue
    sync = EApi.synchronize(E.admin).value!
    {sync.transmitted, sync.errors}.should eq({1, [] of String})
    post = flow_calls("/api/orchestrator/v1/flows").find!(&.method.==("POST"))
    # Identifiant de requête en paramètre (EsaLink) et en en-tête (norme),
    # clé d'API, jeton.
    URI.parse(post.url).query_params["Request-Id"].should eq(post.headers["Request-Id"])
    post.headers["hubtimize-api-key"].should eq(S::SimulatedEsalink::API_KEY)
    post.headers["Authorization"].should start_with("Bearer esl-")
    post.headers["Content-Type"].should start_with("multipart/form-data; boundary=")
    flow = S.platform.sent("CustomerInvoice").first
    {flow.syntax, flow.rule, flow.tracking_id}.should eq({"Factur-X", "B2B", E.transmission(invoice).tracking_id})
    flow.content.should eq(Inv.document_pdf(E::SYSTEM, invoice.id).content)
    row = E.transmission(invoice)
    {row.status, row.adapter, row.platform_ref}.should eq({"submitted", "ESALINK", flow.id})

    S.platform.acknowledge(flow, "Ok")
    EApi.synchronize(E.admin).value!.statuses.should eq(1)
    E.transmission(invoice).status.should eq("deposited")
    EApi.synchronize(E.admin).value!.statuses.should eq(0)
  end

  it "reçoit toutes les factures d'une recherche sans nextCursor, page après page, sans doublon" do
    ready
    E.supplier
    7.times do |index|
      number = "FM-2026-#{700 + index}"
      S.platform.deliver(E.ubl_invoice(number), "#{number}.xml", "UBL")
    end
    EApi.synchronize(E.admin).value!.received.should eq(7)
    Einvoicing::Reception.all.count.should eq(7)
    searches = flow_calls("/flows/search").map { |request| JSON.parse(String.new(request.body || Bytes.empty)) }
    incoming = searches.select { |body| body["where"]["flowType"].as_a.map(&.as_s) == ["SupplierInvoice"] }
    # EsaLink simulée plafonne à trois flux par page : relecture complète
    # demandée (limit = total), encore plafonnée, puis pages par date avec
    # une seconde de recul, sans curseur (D-ESL-002).
    incoming.none? { |body| body["cursor"]? }.should be_true
    incoming[0]["where"]["updatedAfter"]?.should be_nil
    incoming[0]["limit"].as_i.should eq(Esalink::Connector::PAGE_LIMIT)
    incoming[1]["limit"].as_i.should eq(7)
    incoming[2]["where"]["updatedAfter"].as_s.should eq((S.platform.flows[2].updated_at - 1.second).to_rfc3339(fraction_digits: 3))
    incoming.size.should eq(5)
    # Téléchargements demandés en application/octet-stream.
    downloads = S.platform.calls.select { |request| request.method == "GET" && request.url.includes?("docType=Original") }
    # Le recul d'une seconde relit le dernier flux de chaque page (écarté
    # par l'enregistrement idempotent) : sept flux distincts, neuf lectures.
    downloads.map { |request| URI.parse(request.url).path }.uniq!.size.should eq(7)
    downloads.size.should eq(9)
    downloads.all? { |request| request.headers["Accept"] == "application/octet-stream" }.should be_true

    EApi.synchronize(E.admin).value!.received.should eq(0)
    S.platform.deliver(E.ubl_invoice("FM-2026-0800"), "FM-2026-0800.xml", "UBL")
    EApi.synchronize(E.admin).value!.received.should eq(1)
    Einvoicing::Reception.all.count.should eq(8)
  end

  it "lit les statuts de l'acheteur (CDAR) et émet « Refusée » (210)" do
    ready
    invoice = E.issue
    EApi.synchronize(E.admin).value!
    S.platform.acknowledge(S.platform.sent("CustomerInvoice").first, "Ok")
    S.platform.buyer_status(invoice.number.to_s, "210", "DOUBLON", "Facture déjà reçue")
    EApi.synchronize(E.admin).value!.statuses.should eq(2)
    E.transmission(invoice).status.should eq("refused")
    # Refus d'une facture reçue : statut CDAR déposé par POST /flows.
    E.supplier
    S.platform.deliver(E.ubl_invoice, "FM-2026-0412.xml", "UBL")
    EApi.synchronize(E.admin).value!
    reception = EApi.receptions(E.admin, EApi::ReceptionQuery.new(status: nil)).first
    EApi.refuse(E.admin, reception.id, EApi::RefuseInput.new("DOUBLON", "déjà reçue")).value!.status.should eq("refused")
    S.platform.sent(syntax: "CDAR").size.should eq(1)
    flow_calls("/api/orchestrator/v1/flows").count(&.method.==("POST")).should eq(2)
  end

  it "signale une plateforme injoignable ou un refus sans perdre le curseur" do
    ready
    E.supplier
    S.platform.deliver(E.ubl_invoice, "FM-2026-0412.xml", "UBL")
    S.platform.fail_next = 503
    sync = EApi.synchronize(E.admin).value!
    sync.received.should eq(0)
    sync.errors.should_not be_empty
    EApi.synchronize(E.admin).value!.received.should eq(1)
  end
end
