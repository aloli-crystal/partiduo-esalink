# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Suite d'intégration contre la *vraie* préproduction EsaLink
# (`https://ppd.hubtimize.fr/api/orchestrator/v1/`), activée seulement si
# des identifiants existent : variables `ESALINK_SANDBOX_USERNAME`,
# `ESALINK_SANDBOX_PASSWORD`, et facultatives `ESALINK_SANDBOX_API_KEY`,
# `ESALINK_SANDBOX_URL`, lues dans l'environnement ou, à défaut, dans
# `~/.config/partiduo/esalink-sandbox.env` (lignes `VAR=valeur`, lues comme
# le shell : commentaire final, guillemets). `ESALINK_SANDBOX=off` la
# désactive.
#
# Lecture seule : jeton, contrôle de santé, recherche de flux ; rien n'est
# déposé. Les secrets ne sont jamais affichés ni journalisés : le jeton
# reste en mémoire (raccordement sans ligne en base), les messages d'échec
# ne citent que des codes de statut.
module Esalink
  module SpecSupport
    module Preproduction
      REQUIRED = %w[ESALINK_SANDBOX_USERNAME ESALINK_SANDBOX_PASSWORD]
      OPTIONAL = %w[ESALINK_SANDBOX_API_KEY ESALINK_SANDBOX_URL]
      FILE     = Path.home.join(".config", "partiduo", "esalink-sandbox.env").to_s

      def self.credentials : Hash(String, String)?
        return if ENV["ESALINK_SANDBOX"]? == "off"
        values = {} of String => String
        if File.exists?(FILE)
          File.each_line(FILE) do |line|
            name, separator, value = line.strip.partition('=')
            next if separator.empty? || name.starts_with?('#')
            value = value.sub(/\s+#.*\z/, "").strip
            value = value[1..-2] if value.size >= 2 && value[0] == value[-1] && value[0].in?('"', '\'')
            values[name.strip.lchop("export ").strip] = value
          end
        end
        (REQUIRED + OPTIONAL).each { |name| ENV[name]?.presence.try { |value| values[name] = value } }
        REQUIRED.all? { |name| values[name]?.presence } ? values : nil
      end

      def self.connector(values : Hash(String, String)) : Esalink::Connector
        plain = {"environment" => "preproduction", "username" => values["ESALINK_SANDBOX_USERNAME"],
                 "preproduction_url" => values["ESALINK_SANDBOX_URL"]? || ""}
        secrets = {"password" => values["ESALINK_SANDBOX_PASSWORD"], "api_key" => values["ESALINK_SANDBOX_API_KEY"]? || ""}
        Esalink::Connector.new(Einvoicing::Connections::Settings.new(Esalink::ADAPTER, plain, secrets))
      end

      # Exécute le bloc sur le réseau réel (TLS vérifié), puis rétablit
      # EsaLink simulée.
      def self.online(&)
        Einvoicing::Http.transport = nil
        yield
      ensure
        Esalink::SpecSupport.reset_platform
      end
    end
  end
end

private alias P = Esalink::SpecSupport::Preproduction

describe "Intégration contre la préproduction EsaLink (facultative)" do
  credentials = P.credentials

  if credentials
    it "obtient un jeton et passe le contrôle de santé" do
      P.online do
        connector = P.connector(credentials)
        connector.mode.should eq("sandbox")
        connector.check
      end
    end

    it "recherche les flux reçus sans erreur (lecture seule)" do
      P.online do
        page = P.connector(credentials).fetch_statuses(nil)
        page.items.should be_a(Array(Einvoicing::Connector::LifecycleEvent))
      end
    end
  else
    pending "identifiants de préproduction absents (#{P::FILE} vide ou manquant, BLOCAGES B-ESL-001)" { }
  end
end
