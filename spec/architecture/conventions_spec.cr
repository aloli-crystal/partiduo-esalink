# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"
require "../../lib/partiduo-ui-bulma/scripts/api_boundary"

private def source_files(pattern : String) : Array(String)
  Dir.glob(File.join(Esalink::SpecSupport::ROOT, pattern)).reject(&.includes?("/lib/")).sort!
end

private def flatten_keys(value : YAML::Any, prefix : String = "") : Array(String)
  if hash = value.as_h?
    hash.flat_map { |key, child| flatten_keys(child, prefix.empty? ? key.as_s : "#{prefix}.#{key.as_s}") }
  else
    [prefix]
  end
end

describe "Conventions de l'extension ESALINK" do
  it "ouvre chaque fichier source par l'en-tête SPDX" do
    missing = (source_files("{src,ui,spec,config,scripts}/**/*.{cr,sh}") + source_files("*.cr")).reject do |path|
      lines = File.read_lines(path)
      (path.ends_with?(".sh") ? lines[1]? : lines.first?) == "# SPDX-License-Identifier: AGPL-3.0-or-later"
    end
    missing += source_files("ui/**/*.html").reject do |path|
      File.read(path).starts_with?("{# SPDX-License-Identifier: AGPL-3.0-or-later")
    end
    missing.should be_empty
  end

  it "a les mêmes clés de traduction en fr, en et nl" do
    %w[src/esalink/locales ui/bulma/locales].each do |dir|
      keys = Partiduo::LOCALES.to_h do |locale|
        tree = YAML.parse(File.read(File.join(Esalink::SpecSupport::ROOT, dir, "#{locale}.yml")))
        {locale, flatten_keys(tree[locale]).sort}
      end
      keys["en"].should eq(keys["fr"])
      keys["nl"].should eq(keys["fr"])
    end
  end

  it "traduit toute clé citée par le code et les gabarits de l'extension" do
    cited = source_files("{src,ui}/**/*.{cr,html}").flat_map do |path|
      File.read(path).scan(/["'](esalink(?:_ui)?\.[a-z_]+(?:\.[a-z0-9_]+)+)["']/).map(&.[1])
    end.uniq! - Partiduo::Modules[Esalink::CODE].permissions
    cited.size.should be > 30
    dynamic = ["esalink.adapter"]
    %w[sandbox production].each { |code| dynamic << "esalink.modes.#{code}" }
    Esalink::Api::DEVIATIONS.each { |code| dynamic << "esalink.deviations.#{code}" }
    Esalink::Api::ENVIRONMENTS.each { |code| dynamic << "esalink.environments.#{code}" }
    Esalink::Connector::FIELDS.each { |field| dynamic << field.label_key }
    missing = Partiduo::LOCALES.flat_map do |locale|
      I18n.with_locale(locale) do
        (cited + dynamic).select { |key| I18n.t(key).includes?("missing") }.map { |key| "#{locale}:#{key}" }
      end
    end
    missing.should be_empty
  end

  it "n'écrit aucune clé dans l'espace d'une autre extension (D-ESL-005, ADR-006 D3)" do
    Dir.glob(File.join(Esalink::SpecSupport::ROOT, "{src,ui}", "**", "locales", "*.yml")).each do |path|
      roots = YAML.parse(File.read(path)).as_h.values.flat_map { |tree| tree.as_h.keys.map(&.as_s) }
      roots.each { |root| %w[esalink esalink_ui].should contain(root) }
    end
    Esalink::Connector::FIELDS.each do |field|
      field.label_key.should start_with("esalink.fields.")
      field.choice_prefix.should eq("esalink.environments") if field.kind == "choice"
    end
  end

  it "n'a ni table ni migration : son raccordement est celui d'EINV (ADR-003 D5)" do
    Dir.exists?(File.join(Esalink::SpecSupport::ROOT, "src", "esalink", "models")).should be_false
    Dir.exists?(File.join(Esalink::SpecSupport::ROOT, "src", "esalink", "migrations")).should be_false
    Marten.apps.get("esalink").models.should be_empty
  end

  it "ne parle au cœur, depuis ui/bulma, que par Partiduo::Api (ADR-005 D3)" do
    root = Esalink::SpecSupport::ROOT
    ApiBoundary.scan([File.join(root, "ui")], base: root).map(&.to_s).should eq([] of String)
  end

  it "ne parle aux métiers d'extension, depuis ui/bulma, que par leur module Api (ADR-005 D4)" do
    allowed = %w[Api Ui CODE VERSION]
    leaks = source_files("ui/**/*.cr").flat_map do |path|
      File.read_lines(path).each_with_index(1).flat_map do |line, number|
        ApiBoundary.strip_comment(line).scan(/(?<![\w:])(Esalink|Einvoicing|Document)::([A-Za-z_]\w*)/).compact_map do |match|
          "#{path.lchop(Esalink::SpecSupport::ROOT + "/")}:#{number} #{match[1]}::#{match[2]}" unless allowed.includes?(match[2])
        end
      end
    end
    leaks.should be_empty
  end

  it "ne parle au cœur, depuis src/, que par Partiduo::Api (ADR-006 D3)" do
    leaks = source_files("src/**/*.cr").select do |path|
      File.read(path).matches?(/Partiduo::(Invoicing|Accounting|Cards|Core|Vat)::/)
    end
    leaks.map(&.lchop(Esalink::SpecSupport::ROOT + "/")).should be_empty
  end

  it "ne cite d'EINV que sa surface d'adaptateur (adaptateur XP Z12-013, raccordements, transport, contrat)" do
    allowed = %w[Api Connector Connectors ConnectorError Connections Connection Http ErrorText]
    leaks = source_files("src/**/*.cr").flat_map do |path|
      code = File.read_lines(path).map { |line| ApiBoundary.strip_comment(line) }.join('\n')
      code.scan(/(?<![\w:])Einvoicing::([A-Za-z_]\w*)/).map(&.[1]).reject { |name| allowed.includes?(name) }
        .map { |name| "#{path.lchop(Esalink::SpecSupport::ROOT + "/")} Einvoicing::#{name}" }
    end
    leaks.uniq.should be_empty
  end

  it "n'utilise que des icônes de la planche de l'interface (ADR-005 D5)" do
    lucide = File.join(Esalink::SpecSupport::ROOT, "lib", "partiduo-ui-bulma", "icons", "lucide")
    known = Dir.glob(File.join(lucide, "*.svg")).map { |path| File.basename(path, ".svg") }
    known.should_not be_empty
    used = source_files("ui/bulma/templates/**/*.html").flat_map do |path|
      File.read(path).scan(/_icon\.html" with name="([a-z0-9-]+)"/).map { |match| "#{path.lchop(Esalink::SpecSupport::ROOT + "/")} #{match[1]}" }
    end
    used.reject { |item| known.includes?(item.split(' ').last) }.should be_empty
  end
end
