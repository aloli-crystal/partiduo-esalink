# SPDX-License-Identifier: AGPL-3.0-or-later

module Esalink
  module SpecSupport
    alias E = Einvoicing::SpecSupport
    alias Api = Esalink::Api

    SYSTEM = Partiduo::Api::Actor.system

    @@platform : SimulatedEsalink?

    def self.platform : SimulatedEsalink
      @@platform || raise "EsaLink simulée absente"
    end

    def self.reset_platform : SimulatedEsalink
      platform = SimulatedEsalink.new
      @@platform = platform
      Einvoicing::Http.transport = platform
      platform
    end

    # Administrateur du dossier : permissions d'EINV et d'ESALINK.
    def self.admin : Partiduo::Api::Actor
      Partiduo::Api::Actor.user(E.admin.user_id || 1_i64, E::PERMISSIONS + [Api::CONFIGURE], level: 3)
    end

    # Dossier d'EINV (régime `fr` ou `be`) avec ESALINK actif.
    def self.books(regime : String = "fr") : Nil
      E.books(regime)
      Partiduo::Api::Modules.activate(SYSTEM, "ESALINK").value!
      nil
    end

    def self.input(environment : String = "preproduction", password : String = SimulatedEsalink::PASSWORD,
                   api_key : String = SimulatedEsalink::API_KEY, production_url : String = "") : Api::ConnectionInput
      Api::ConnectionInput.new(environment: environment, username: SimulatedEsalink::USERNAME, password: password,
        api_key: api_key, production_url: production_url)
    end

    # Raccordement en préproduction avec les identifiants de la société.
    def self.connect(environment : String = "preproduction") : Api::StatusView
      url = environment == "production" ? SimulatedEsalink::PRODUCTION_URL : ""
      Api.connect(admin, input(environment, production_url: url)).value!
    end

    # Connecteur du raccordement actif.
    def self.connector : Esalink::Connector
      Einvoicing::Connections.connector.as(Esalink::Connector)
    end
  end
end

# Chaque exemple part d'une EsaLink simulée vierge (après la plateforme
# simulée d'EINV, remplacée).
Spec.before_each do
  Esalink::SpecSupport.reset_platform
end
