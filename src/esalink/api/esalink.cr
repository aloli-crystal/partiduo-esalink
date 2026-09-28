# SPDX-License-Identifier: AGPL-3.0-or-later

module Esalink
  # Contrat public de l'extension ESALINK, sur le modèle de `Partiduo::Api`
  # (DECISIONS C2) : acteur en premier argument, contrôle d'accès en première
  # ligne, objets de vue immuables, erreurs par champ. L'interface de
  # l'extension (`ui/bulma/`) ne voit que ce module, `Einvoicing::Api` et
  # `Partiduo::Api`.
  #
  # Tout le reste (factures, statuts, e-reporting, annuaire) passe par
  # `Einvoicing::Api`, qui appelle l'adaptateur EsaLink une fois le dossier
  # raccordé.
  #
  # Référence : `doc/api/esalink.adoc`.
  module Api
    alias Actor = Partiduo::Api::Actor
    alias Guard = Partiduo::Api::Guard
    alias Result = Partiduo::Api::Result
    alias FieldError = Partiduo::Api::FieldError
    alias Connections = Einvoicing::Connections

    MODULE_CODE = Esalink::CODE

    # Écran, état et essai du raccordement. Enregistrer ou débrancher exige
    # en plus `einvoicing.settings.manage`, vérifiée par `Einvoicing::Api`.
    CONFIGURE = "esalink.connection.manage"

    ENVIRONMENTS = Connector::ENVIRONMENTS
    DEVIATIONS   = Connector::DEVIATIONS

    # Adresse de préproduction par défaut.
    PREPRODUCTION_URL = Connector::PREPRODUCTION_URL

    # --- État --------------------------------------------------------------------

    def self.status(actor : Actor) : StatusView
      Guard.authorize!(actor, CONFIGURE, module_code: MODULE_CODE)
      row = self.row
      settings = row.try { |item| Connections.settings_of(item) }
      active = Connections.active
      connected = !!(active && active.adapter == ADAPTER)
      environment = settings.try(&.["environment"]).presence || "preproduction"
      effective = settings ? (Connector.base_url(settings) rescue "") : PREPRODUCTION_URL
      StatusView.new(
        connected: connected, configured: !row.nil?, other_adapter: active && !connected ? active.adapter : nil,
        environment: environment, mode: environment == "production" ? "production" : "sandbox",
        username: settings.try(&.["username"]) || "",
        password_stored: !(settings.try(&.secrets["password"]?) || "").empty?,
        api_key_stored: !(settings.try(&.secrets["api_key"]?) || "").empty?,
        preproduction_url: settings.try(&.["preproduction_url"]) || "",
        production_url: settings.try(&.["production_url"]) || "",
        directory_url: settings.try(&.["directory_url"]) || "",
        effective_url: effective, last_sync_at: row.try(&.last_sync_at),
        last_error: Einvoicing::ErrorText.translate(row.try(&.last_error) || ""))
    end

    # --- Raccordement ------------------------------------------------------------

    # Contrôle les paramètres, *essaie* l'authentification (`/token`) et le
    # contrôle de santé avec eux, puis les enregistre par
    # `Einvoicing::Api.configure` (secrets chiffrés) : EsaLink devient
    # l'adaptateur actif d'EINV. Un secret laissé vide garde la valeur
    # enregistrée. Rien n'est enregistré si l'essai échoue.
    def self.connect(actor : Actor, input : ConnectionInput) : Result(StatusView)
      authorize_linking!(actor)
      adapter = Connections.adapter?(ADAPTER) || raise "adaptateur #{ADAPTER} non enregistré"
      existing = row
      values = input.values.transform_values(&.strip)
      errors = [] of FieldError
      Connections.check(adapter, ADAPTER, values, existing, regime, errors)
      if values["environment"] == "production" && values["production_url"].empty?
        errors << FieldError.new("production_url", "esalink.errors.connection.production_url")
      end
      return Result(StatusView).failure(errors) unless errors.empty?

      begin
        trial(values, existing).check
      rescue ex : Einvoicing::ConnectorError
        return Result(StatusView).failure(FieldError.base("esalink.errors.connection.failed", {"detail" => ex.localized}))
      end

      saved = Einvoicing::Api.configure(actor, Einvoicing::Api::ConnectionInput.new(ADAPTER, values))
      return Result(StatusView).failure(saved.errors) if saved.failure?
      Result(StatusView).success(status(actor))
    end

    # Essai du raccordement actif : jeton (redemandé s'il a expiré) et
    # contrôle de santé.
    def self.check(actor : Actor) : Result(CheckView)
      Guard.authorize!(actor, CONFIGURE, module_code: MODULE_CODE)
      current = row
      unless current && current.active
        return Result(CheckView).failure(FieldError.base("esalink.errors.connection.missing"))
      end
      connector = Connections.connector(current).as(Connector)
      connector.check
      Result(CheckView).success(CheckView.new(connector.mode, connector.base_url, Time.utc))
    rescue ex : Einvoicing::ConnectorError
      Result(CheckView).failure(FieldError.base("esalink.errors.connection.failed", {"detail" => ex.localized}))
    end

    # Débranche EsaLink (plus rien n'est transmis ni reçu) ; les paramètres
    # restent enregistrés, le jeton en cours est oublié.
    def self.disconnect(actor : Actor) : Result(Nil)
      authorize_linking!(actor)
      current = row
      unless current && current.active
        return Result(Nil).failure(FieldError.base("esalink.errors.connection.missing"))
      end
      Einvoicing::Api.disconnect(actor)
    end

    # --- Outils ------------------------------------------------------------------

    # Raccordement d'EsaLink enregistré (actif ou non).
    private def self.row : Einvoicing::Connection?
      Einvoicing::Connection.filter(adapter: ADAPTER).first
    end

    # Connecteur d'essai sur les paramètres saisis, complétés des secrets
    # enregistrés ; aucun jeton n'est conservé.
    private def self.trial(values : Hash(String, String), existing : Einvoicing::Connection?) : Connector
      secrets = existing ? Connections.settings_of(existing).secrets.dup : {} of String => String
      plain = {} of String => String
      Connector::FIELDS.each do |field|
        value = values[field.name]? || ""
        if field.secret
          secrets[field.name] = value unless value.empty?
        else
          plain[field.name] = value
        end
      end
      Connector.new(Connections::Settings.new(ADAPTER, plain, secrets))
    end

    private def self.regime : String
      Partiduo::Api::Core.settings(Actor.system).tax_regime
    rescue Partiduo::Api::NotFound
      ""
    end

    # Enregistrer ou débrancher exige aussi `einvoicing.settings.manage`,
    # vérifiée avant tout appel à EsaLink.
    private def self.authorize_linking!(actor : Actor) : Nil
      Guard.authorize!(actor, CONFIGURE, module_code: MODULE_CODE)
      Guard.authorize!(actor, Einvoicing::Api::CONFIGURE, module_code: Einvoicing::Api::MODULE_CODE)
    end
  end
end
