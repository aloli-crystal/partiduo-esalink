# SPDX-License-Identifier: AGPL-3.0-or-later

module Esalink
  module Ui
    # Ligne présentée à un gabarit : textes déjà mis en forme, par nom
    # (un grand `Hash` n'est pas lu par les gabarits Marten, BLOCAGES
    # B-EINV-001).
    class Row
      include Marten::Template::Object

      getter values : Hash(String, String?)

      def initialize(@values : Hash(String, String?))
      end

      def [](key : String) : String?
        values[key]?
      end

      def resolve_template_attribute(key : String)
        values[key]?
      end
    end

    def self.row(values : Hash(String, String?)) : Row
      Row.new(values)
    end

    def self.url(name : String) : String
      Marten.routes.reverse("esalink:#{name}")
    end

    # Présentation de l'état du raccordement.
    module Present
      alias Api = Esalink::Api

      def self.status(view : Api::StatusView, fmt : PartiduoUi::Format) : Row
        Ui.row({
          "connected"       => view.connected ? "1" : nil,
          "configured"      => view.configured ? "1" : nil,
          "other_adapter"   => view.other_adapter,
          "environment"     => view.environment,
          "environment_l"   => I18n.t(view.environment_key),
          "mode"            => view.mode,
          "username"        => view.username,
          "password_stored" => view.password_stored ? "1" : nil,
          "api_key_stored"  => view.api_key_stored ? "1" : nil,
          "effective_url"   => view.effective_url.presence,
          "last_sync"       => view.last_sync_at.try { |time| fmt.datetime(time) },
          "last_error"      => view.last_error.presence,
        })
      end

      # Environnements proposés, celui en cours sélectionné.
      def self.environments(selected : String) : Array(Row)
        Api::ENVIRONMENTS.map do |code|
          Ui.row({"value" => code, "label" => I18n.t("einvoicing.modes.#{code}"), "selected" => code == selected ? "1" : nil})
        end
      end

      # Écarts constatés à la norme XP Z12-013.
      def self.deviations : Array(Row)
        Api::DEVIATIONS.map { |code| Ui.row({"code" => code, "label" => I18n.t("esalink.deviations.#{code}")} of String => String?) }
      end
    end
  end
end
