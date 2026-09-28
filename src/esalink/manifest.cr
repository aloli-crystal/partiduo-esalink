# SPDX-License-Identifier: AGPL-3.0-or-later

# Manifeste de l'extension ESALINK (ADR-003 D2, ADR-004 D2) : l'adaptateur
# de la plateforme agréée EsaLink, rien d'autre.
#
# * Dépendance : `EINV` (`depends_on`), dont elle réutilise l'adaptateur
#   XP Z12-013 ; EINV dépend lui-même de DOCUMENT.
# * Permission : `esalink.connection.manage` (écran de raccordement, état,
#   essai de la connexion). Enregistrer ou débrancher le raccordement passe
#   par `Einvoicing::Api`, qui exige en plus `einvoicing.settings.manage`
#   (même règle que SUPERPDP, DECISIONS D-SPDP-003).
# * Menu : « EsaLink » sous « Paramètres », à côté du raccordement d'EINV.
# * Aucun abonnement : émission, réception, statuts et e-reporting sont
#   conduits par EINV, qui appelle l'adaptateur.
Partiduo::Modules.register do
  code "ESALINK"
  name "esalink.module.name"
  version "0.1.0"
  requires_core "~> 0.1"
  depends_on "EINV"

  permission "esalink.connection.manage"

  menu "ESALINK", parent: "SETTINGS", order: 92, route: "esalink:index", permission: "esalink.connection.manage",
    label: "esalink.menu.esalink"

  ui "bulma", path: "ui/bulma"
end
