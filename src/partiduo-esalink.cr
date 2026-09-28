# SPDX-License-Identifier: AGPL-3.0-or-later

# Point d'entrée du shard `partiduo-esalink` : le métier de l'extension
# ESALINK (manifeste, adaptateur EsaLink hérité de l'adaptateur XP Z12-013
# d'EINV, contrat `Esalink::Api`), sans interface. L'interface Bulma est
# dans `ui/bulma/`, requise à part par la distribution :
# `require "partiduo-esalink/ui/bulma"`.
#
# La distribution ajoute ensuite `Esalink::INSTALLED_APPS` à ses
# applications Marten, après celles de `partiduo-einvoicing`. L'extension
# n'a ni table ni migration : son raccordement est celui d'EINV
# (`einvoicing_connection`, secrets et jetons chiffrés).
require "partiduo"
require "partiduo-document"
require "partiduo-einvoicing"

require "./esalink/app"
