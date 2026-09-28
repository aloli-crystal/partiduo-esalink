# SPDX-License-Identifier: AGPL-3.0-or-later

# Interface Bulma de l'extension ESALINK (ADR-005 D4) : écran de
# raccordement à EsaLink — identifiants (identifiant, mot de passe, clé
# d'API), environnement (préproduction ou production, toujours affiché),
# adresses, essai de la connexion, déconnexion, écarts constatés à la
# norme. Montée par `partiduo-ui-bulma` sous `/ext/ESALINK/` (ADR-003 D3).
# La distribution la requiert après l'interface et celle d'EINV :
#
# ```
# require "partiduo-ui-bulma/partiduo_ui"
# require "partiduo-esalink"
# require "partiduo-document/ui/bulma"
# require "partiduo-einvoicing/ui/bulma"
# require "partiduo-esalink/ui/bulma"
# ```
#
# puis ajoute `Esalink::Ui::INSTALLED_APPS` à ses applications Marten.
#
# Ce dossier ne parle au métier que par `Esalink::Api` et `Partiduo::Api`
# (vérifié par `spec/architecture/conventions_spec.cr`) ; le contrôle d'accès
# est fait par l'interface, avant le handler, à partir du manifeste.
require "../../src/partiduo-esalink"

require "./presenters"
require "./handlers/**"

module Esalink
  module Ui
    # Application Marten de l'interface Bulma de l'extension : gabarits
    # (`templates/esalink/`) et libellés d'écran (`locales/`, clés
    # `esalink_ui.*`).
    class App < Marten::App
      label "esalink_ui"
    end

    INSTALLED_APPS = [Esalink::Ui::App] of Marten::Apps::Config.class

    # Routes servies sous `/ext/ESALINK/`, nommées `esalink:<nom>`.
    ROUTES = Marten::Routing::Map.draw do
      path "/", Esalink::Ui::IndexHandler, name: "index"
      path "/connect", Esalink::Ui::ConnectHandler, name: "connect"
      path "/check", Esalink::Ui::CheckHandler, name: "check"
      path "/disconnect", Esalink::Ui::DisconnectHandler, name: "disconnect"
    end
  end
end

PartiduoUi::Extensions.mount Esalink::CODE, Esalink::Ui::ROUTES, permission: Esalink::Api::CONFIGURE
