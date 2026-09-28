# SPDX-License-Identifier: AGPL-3.0-or-later

module Esalink
  # Adaptateur EsaLink (Hubtimize e-Invoicing) de `Einvoicing::Connector`
  # (ADR-004 D2). L'API d'orchestration d'EsaLink
  # (`…/api/orchestrator/v1/flows`) suit l'API Flux de la norme XP Z12-013 :
  # l'adaptateur *hérite* de celui d'EINV (`Einvoicing::Connectors::Afnor` :
  # dépôt `POST /flows` en `multipart/form-data` avec `flowInfo`, syntaxe
  # Factur-X, `processingRule`, `trackingId`, empreinte SHA-256 ; recherche
  # `POST /flows/search` ; téléchargement `GET /flows/{flowId}?docType=…` ;
  # statuts CDAR ; e-reporting ; annuaire) et ne redéfinit que ce qui est
  # propre à EsaLink :
  #
  # * authentification par identifiant et mot de passe : `POST /token` en
  #   JSON (`username`, `password`), qui rend `access_token` et
  #   `expires_in` ; aucune route de rafraîchissement : le jeton est
  #   redemandé à l'expiration (ou sur un refus 401), conservé chiffré par
  #   EINV ;
  # * clé d'API facultative, en-tête `hubtimize-api-key` sur chaque appel ;
  # * adresses de préproduction (`https://ppd.hubtimize.fr/api/orchestrator/v1/`
  #   par défaut) et de production paramétrables, l'environnement choisi
  #   fixant le mode affiché ;
  # * adresse d'authentification facultative (`token_url`, par défaut
  #   `<adresse de l'API>token`) ;
  # * contrôle de santé `GET /healthcheck` (authentifié) ;
  # * écarts constatés à la norme (`DEVIATIONS`, DECISIONS D-ESL-003).
  #
  # Source d'information : le module libre PDPConnectFR de Dolibarr
  # (GPL-3.0, `class/providers/EsalinkPDPProvider.class.php`), lu pour
  # comprendre l'API ; aucun code n'en est repris.
  class Connector < Einvoicing::Connectors::Afnor
    alias Connections = Einvoicing::Connections
    alias Http = Einvoicing::Http
    alias ConnectorError = Einvoicing::ConnectorError

    # Adresse de préproduction publiée (celle qu'utilise PDPConnectFR).
    PREPRODUCTION_URL = "https://ppd.hubtimize.fr/api/orchestrator/v1/"

    # Environnements proposés ; libellés `esalink.environments.<code>`.
    ENVIRONMENTS = %w[preproduction production]

    # En-tête de la clé d'API d'EsaLink.
    API_KEY_HEADER = "hubtimize-api-key"

    # Flux demandés par page de recherche : EsaLink ne rend pas de
    # `nextCursor` (écart `search_without_cursor`), une page large limite
    # les allers-retours.
    PAGE_LIMIT = 200

    # Recherche incomplète relue d'un seul appel (`limit = total`) jusqu'à
    # ce nombre de flux, comme PDPConnectFR : EsaLink ne garantit pas le tri
    # par `updatedAt` (DECISIONS D-ESL-002).
    FULL_READ_LIMIT = 5000

    # Durée de vie d'un jeton rendu sans `expires_in` (prudente).
    DEFAULT_TOKEN_LIFETIME = 15.minutes

    # Écarts constatés entre l'API d'EsaLink et la norme XP Z12-013, et la
    # façon dont l'adaptateur les absorbe. Libellés
    # `esalink.deviations.<code>`.
    DEVIATIONS = %w[token_password api_key_header request_id_query download_accept search_without_cursor
      no_refresh_token production_url]

    # Libellés `esalink.fields.<nom>` (DECISIONS D-ESL-005).
    FIELDS = [
      Connections::Field.new("environment", kind: "choice", choices: ENVIRONMENTS, label: "esalink.fields.environment",
        choice_prefix: "esalink.environments"),
      Connections::Field.new("username", label: "esalink.fields.username"),
      Connections::Field.new("password", secret: true, label: "esalink.fields.password"),
      Connections::Field.new("api_key", secret: true, required: false, label: "esalink.fields.api_key"),
      Connections::Field.new("preproduction_url", kind: "url", required: false, label: "esalink.fields.preproduction_url"),
      Connections::Field.new("production_url", kind: "url", required: false, label: "esalink.fields.production_url"),
      Connections::Field.new("directory_url", kind: "url", required: false, label: "esalink.fields.directory_url"),
      Connections::Field.new("token_url", kind: "url", required: false, label: "esalink.fields.token_url"),
    ]

    def self.adapter : Connections::Adapter
      Connections::Adapter.new(ADAPTER, "esalink.adapter", %w[fr], FIELDS,
        ->(settings : Connections::Settings) { new(settings).as(Einvoicing::Connector) })
    end

    # Adresse de l'API d'orchestration pour l'environnement choisi,
    # terminée par `/` ; lève `ConnectorError` en production sans adresse.
    def self.base_url(settings : Connections::Settings) : String
      url = if settings["environment"] == "production"
              settings["production_url"].presence ||
                raise ConnectorError.new("adresse de production d'EsaLink non renseignée", nil,
                  "esalink.errors.transport.no_production_url")
            else
              settings["preproduction_url"].presence || PREPRODUCTION_URL
            end
      url.ends_with?('/') ? url : "#{url}/"
    end

    def mode : String
      settings["environment"] == "production" ? "production" : "sandbox"
    end

    # Adresse effective de l'API d'orchestration.
    def base_url : String
      Connector.base_url(settings)
    end

    # Adresse d'authentification : `token_url` si elle est renseignée,
    # sinon `<adresse de l'API>token`. PDPConnectFR distingue les deux
    # adresses (identiques en préproduction, inconnues en production) :
    # hypothèse à vérifier au premier essai en production (B-ESL-001).
    def self.token_url(settings : Connections::Settings) : String
      settings["token_url"].presence || "#{base_url(settings)}token"
    end

    def token_url : String
      Connector.token_url(settings)
    end

    # --- Points d'extension de l'adaptateur XP Z12-013 --------------------------

    # Les chemins de l'API Flux (`/v1/flows`) sont relatifs à l'adresse
    # d'orchestration, qui porte déjà la version (`…/orchestrator/v1/`).
    protected def flow_url(path : String) : String
      "#{base_url}#{path.lchop("/v1").lchop('/')}"
    end

    # Clé d'API, si elle est renseignée ; pas d'`Organization-Id`.
    protected def platform_headers : Hash(String, String)
      key = settings["api_key"]
      key.empty? ? {} of String => String : {API_KEY_HEADER => key}
    end

    # `Request-Id` repris en paramètre d'adresse, comme l'attend EsaLink,
    # en plus de l'en-tête de la norme.
    protected def request_url(url : String, request_id : String) : String
      separator = url.includes?('?') ? '&' : '?'
      "#{url}#{separator}#{URI::Params.encode({"Request-Id" => request_id})}"
    end

    protected def download_accept : String
      "application/octet-stream"
    end

    protected def page_limit : Int32
      PAGE_LIMIT
    end

    protected def full_read_limit : Int32
      FULL_READ_LIMIT
    end

    # Pas de `nextCursor` : d'autres flux restent à lire si le `total`
    # annoncé dépasse la page, ou, sans `total`, si la page est pleine.
    protected def more_without_cursor?(body : JSON::Any, results : Array(JSON::Any)) : Bool
      total = body["total"]?.try { |value| value.as_i64? || value.as_s?.try(&.to_i64?) }
      total ? total > results.size : results.size >= page_limit
    end

    # `POST /token` avec identifiant et mot de passe (JSON) ; le jeton est
    # enregistré chiffré jusqu'à son expiration. Le mot de passe n'apparaît
    # dans aucun message d'erreur.
    protected def authenticate : String
      body = {"username" => settings["username"], "password" => settings["password"]}.to_json
      headers = {"Content-Type" => "application/json", "Accept" => "application/json"}.merge(platform_headers)
      response = Http.exec("POST", token_url, headers, body.to_slice)
      unless response.success?
        raise ConnectorError.new("authentification EsaLink refusée (#{response.status})", response.status,
          "einvoicing.errors.transport.auth_refused", {"status" => response.status.to_s})
      end
      json = response.json
      access = json["access_token"]?.try(&.as_s?).presence ||
               raise ConnectorError.new("réponse de /token sans access_token", nil,
                 "einvoicing.errors.transport.missing_field", {"field" => "access_token"})
      expires = json["expires_in"]?.try { |value| value.as_i64? || value.as_s?.try(&.to_i64?) }
      lifetime = expires ? expires.seconds : DEFAULT_TOKEN_LIFETIME
      settings.store_tokens(access, Time.utc + lifetime)
      access
    end
  end
end
