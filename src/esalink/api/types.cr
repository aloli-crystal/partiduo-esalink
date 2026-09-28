# SPDX-License-Identifier: AGPL-3.0-or-later

module Esalink
  module Api
    # État du raccordement EsaLink, sans appel à la plateforme. Les secrets
    # (mot de passe, clé d'API) ne sont jamais rendus, seulement s'ils sont
    # enregistrés. `mode` : `sandbox` (préproduction) ou `production`,
    # affiché en permanence (ADR-004 D8). `other_adapter` : adaptateur d'une
    # autre plateforme actuellement actif. `can_link` : l'acteur peut
    # enregistrer ou débrancher le raccordement (`einvoicing.settings.manage`).
    record StatusView,
      connected : Bool,
      configured : Bool,
      other_adapter : String?,
      environment : String,
      mode : String,
      username : String,
      password_stored : Bool,
      api_key_stored : Bool,
      preproduction_url : String,
      production_url : String,
      directory_url : String,
      token_url : String,
      effective_url : String,
      last_sync_at : Time?,
      last_error : String,
      can_link : Bool do
      # Clé du libellé de l'environnement.
      def environment_key : String
        "esalink.environments.#{environment}"
      end
    end

    # Paramètres saisis. Un secret laissé vide garde la valeur enregistrée ;
    # une adresse laissée vide prend celle par défaut (préproduction) ou
    # n'est pas utilisée (production, annuaire).
    record ConnectionInput,
      environment : String,
      username : String,
      password : String = "",
      api_key : String = "",
      preproduction_url : String = "",
      production_url : String = "",
      directory_url : String = "",
      token_url : String = "" do
      def values : Hash(String, String)
        {"environment" => environment, "username" => username, "password" => password, "api_key" => api_key,
         "preproduction_url" => preproduction_url, "production_url" => production_url,
         "directory_url" => directory_url, "token_url" => token_url}
      end
    end

    # Résultat d'un essai de la connexion : environnement, adresse appelée,
    # heure de l'essai.
    record CheckView, mode : String, url : String, checked_at : Time do
      def mode_key : String
        "esalink.modes.#{mode}"
      end
    end
  end
end
