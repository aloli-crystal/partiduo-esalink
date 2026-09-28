# SPDX-License-Identifier: AGPL-3.0-or-later

module Esalink
  module SpecSupport
    # EsaLink simulée : double du transport HTTP d'EINV qui reproduit l'API
    # d'orchestration d'EsaLink telle que la décrit PDPConnectFR (DECISIONS
    # D-ESL-003) — `POST /token` en JSON (identifiant, mot de passe), clé
    # `hubtimize-api-key`, `Request-Id` en paramètre d'adresse,
    # téléchargement en `application/octet-stream`, recherche sans
    # `nextCursor` avec `total`, contrôle de santé — devant l'API Flux
    # simulée d'EINV (`SimulatedPlatform`, en mode sans curseur), à laquelle
    # les requêtes conformes sont transmises. Préproduction :
    # `https://ppd.hubtimize.fr/api/orchestrator/v1/` (jamais appelée : le
    # transport est remplacé) ; production : `https://prod.esalink.test/…`.
    class SimulatedEsalink < Einvoicing::SpecSupport::SimulatedPlatform
      USERNAME = "atelier-brunet"
      PASSWORD = "m0t-de-passe-esalink"
      API_KEY  = "cle-hubtimize-42"

      PREPRODUCTION_HOST = "ppd.hubtimize.fr"
      PRODUCTION_HOST    = "prod.esalink.test"
      PRODUCTION_URL     = "https://#{PRODUCTION_HOST}/api/orchestrator/v1/"
      PREFIX             = "/api/orchestrator/v1/"

      # Requêtes reçues par EsaLink (avant transmission à l'API Flux).
      getter calls = [] of Request
      # Hôte de chaque jeton délivré (préproduction ou production).
      getter token_hosts = {} of String => String
      # Clé d'API exigée (`nil` : aucune).
      property api_key : String? = API_KEY
      # Durée de vie annoncée des jetons (`nil` : pas d'`expires_in`).
      property expires_in : Int32? = 3600
      # Contrôle de santé en panne.
      property? unhealthy : Bool = false

      def initialize
        super
        self.cursorless = true
        self.page_size = 3
      end

      def exec(request : Request) : Response
        uri = URI.parse(request.url)
        return super unless uri.host.in?(PREPRODUCTION_HOST, PRODUCTION_HOST)
        @calls << request
        path = uri.path.lchop?(PREFIX) || return json(404, {"message" => "not found"})
        if key = api_key
          return json(403, {"message" => "invalid api key"}) unless request.headers[Esalink::Connector::API_KEY_HEADER]? == key
        end
        return token(request, uri.host.to_s) if path == "token" && request.method == "POST"
        # Jeton valable, délivré pour cet hôte.
        bearer = request.headers["Authorization"]?.to_s.lchop("Bearer ")
        if !tokens.includes?(bearer) || revoked.includes?(bearer) || token_hosts[bearer]? != uri.host
          return json(401, {"message" => "unauthorized"})
        end
        params = uri.query_params
        request_id = params["Request-Id"]?
        return json(400, {"message" => "Request-Id manquant"}) if request_id.nil? || request_id.empty?
        return health if path == "healthcheck" && request.method == "GET"
        if request.method == "GET" && path.starts_with?("flows/") && params["docType"]? != "Metadata" &&
           request.headers["Accept"]? != "application/octet-stream"
          return json(406, {"message" => "not acceptable"})
        end
        params.delete("Request-Id")
        query = params.to_s
        forwarded = Request.new(request.method, "https://pa.test/afnor-flow/v1/#{path}#{query.empty? ? "" : "?#{query}"}",
          request.headers, request.body)
        super(forwarded)
      end

      # Tous les jetons délivrés expirent.
      def expire_tokens : Nil
        tokens.each { |value| revoked << value }
      end

      # Nombre de jetons délivrés.
      def token_count : Int32
        tokens.size
      end

      private def token(request : Request, host : String) : Response
        return json(415, {"message" => "JSON attendu"}) unless request.headers["Content-Type"]?.to_s.starts_with?("application/json")
        body = JSON.parse(String.new(request.body || Bytes.empty)) rescue return json(400, {"message" => "JSON illisible"})
        unless body["username"]?.try(&.as_s?) == USERNAME && body["password"]?.try(&.as_s?) == PASSWORD
          return json(401, {"message" => "Bad credentials"})
        end
        value = "esl-#{tokens.size + 1}"
        tokens << value
        token_hosts[value] = host
        result = {"access_token" => JSON::Any.new(value), "token_type" => JSON::Any.new("Bearer")}
        expires_in.try { |seconds| result["expires_in"] = JSON::Any.new(seconds.to_i64) }
        json(200, result)
      end

      private def health : Response
        unhealthy? ? json(503, {"status" => "DOWN"}) : json(200, {"status" => "UP"})
      end
    end
  end
end
