# SPDX-License-Identifier: AGPL-3.0-or-later

require "./manifest"
require "./connector"
require "./api/**"

# Extension ESALINK de Partiduo : l'adaptateur de la plateforme agréée
# EsaLink (Hubtimize e-Invoicing) pour l'extension EINV (ADR-004 D2).
# Mince : l'API Flux XP Z12-013 est celle de l'adaptateur d'EINV
# (`Einvoicing::Connectors::Afnor`), dont `connector.cr` hérite et ne
# redéfinit que ce qui est propre à EsaLink ; `api/` est le contrat public
# `Esalink::Api` (raccordement, état, contrôle de santé), `locales/` les
# libellés.
module Esalink
  # Lue à la compilation dans `shard.yml`, seule source du numéro : chaque
  # commit y incrémente le dernier chiffre.
  VERSION = {{
              (read_file("#{__DIR__}/../../shard.yml")
                .lines
                .find(&.starts_with?("version:")) || "version: 0.0.0")
                .gsub(/^version:\s*/, "")
                .chomp
            }}

  # Code du registre (ADR-003 D2) : `esalink` dans `PARTIDUO_MODULES`.
  CODE = "ESALINK"

  # Code de l'adaptateur enregistré auprès d'EINV
  # (`Einvoicing::Connections.register`).
  ADAPTER = "ESALINK"

  # Application Marten du métier : libellés seulement (aucune table).
  class App < Marten::App
    label "esalink"
  end

  # Applications Marten du métier, à ajouter à `installed_apps` de la
  # distribution après `Einvoicing::INSTALLED_APPS`.
  INSTALLED_APPS = [Esalink::App] of Marten::Apps::Config.class
end

Einvoicing::Connections.register(Esalink::Connector.adapter)
