# SPDX-License-Identifier: AGPL-3.0-or-later

module Esalink
  module Ui
    # Base des écrans de l'extension. L'accès a déjà été contrôlé par
    # `PartiduoUi::ExtensionHandler` à partir du manifeste ; `Esalink::Api`
    # le vérifie encore.
    abstract class Handler < PartiduoUi::ScreenHandler
      alias Api = Esalink::Api

      def messages(result) : Array(String)
        result.errors.map { |error| fmt.message(error) }
      end

      def back : Marten::HTTP::Response
        go(Ui.url("index"))
      end
    end

    # `/ext/ESALINK/` : état du raccordement et formulaire de raccordement.
    class IndexHandler < Handler
      FIELDS = %w[environment username password api_key preproduction_url production_url directory_url token_url]

      def get
        show({} of String => Array(String))
      end

      def show(errors : Hash(String, Array(String)), values : Hash(String, String)? = nil,
               status : Int32 = 200) : Marten::HTTP::Response
        view = Api.status(current.actor)
        form = values || {
          "environment" => view.environment, "username" => view.username,
          "preproduction_url" => view.preproduction_url, "production_url" => view.production_url,
          "directory_url" => view.directory_url, "token_url" => view.token_url,
        }
        page("esalink/index.html", {
          "title"        => I18n.t("esalink_ui.title"),
          "crumbs"       => [crumb("core.menu.settings"), PartiduoUi::Screen::Crumb.new(I18n.t("esalink_ui.title"))],
          "status"       => Present.status(view, fmt),
          "form"         => Ui.row(form.transform_values { |value| value.as(String?) }),
          "environments" => Present.environments(form["environment"]? || view.environment),
          "deviations"   => Present.deviations,
          "default_url"  => Api::PREPRODUCTION_URL,
          "errors"       => Ui.row(errors.transform_values { |list| list.join(" ").as(String?) }),
          "base"         => errors["base"]?.try(&.join(" ")),
        }, status: status)
      end
    end

    # Essai des identifiants puis enregistrement.
    class ConnectHandler < IndexHandler
      def get
        back
      end

      def post
        values = FIELDS.to_h { |name| {name, field(name)} }
        input = Api::ConnectionInput.new(environment: values["environment"], username: values["username"],
          password: values["password"], api_key: values["api_key"], preproduction_url: values["preproduction_url"],
          production_url: values["production_url"], directory_url: values["directory_url"],
          token_url: values["token_url"])
        result = Api.connect(current.actor, input)
        if result.success?
          flash["success"] = I18n.t("esalink_ui.flash.connected", mode: I18n.t(result.value!.environment_key))
          return back
        end
        # Les secrets saisis ne sont jamais renvoyés dans la page.
        show(errors_of(result), values.merge({"password" => "", "api_key" => ""}), 422)
      end
    end

    # Test de connexion : jeton et contrôle de santé.
    class CheckHandler < Handler
      def get
        back
      end

      def post
        result = Api.check(current.actor)
        if result.success?
          check = result.value!
          flash["success"] = I18n.t("esalink_ui.flash.checked", mode: I18n.t(check.mode_key), url: check.url)
        else
          flash["danger"] = messages(result).join(" ")
        end
        back
      end
    end

    # Déconnexion : EsaLink débranché, paramètres conservés.
    class DisconnectHandler < Handler
      def get
        back
      end

      def post
        result = Api.disconnect(current.actor)
        if result.success?
          flash["success"] = I18n.t("esalink_ui.flash.disconnected")
        else
          flash["danger"] = messages(result).join(" ")
        end
        back
      end
    end
  end
end
