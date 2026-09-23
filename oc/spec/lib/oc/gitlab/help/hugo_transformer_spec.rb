# frozen_string_literal: true

# spec_helper, not fast_spec_helper: the prepend only happens once the class
# has been loaded through the application.
require 'spec_helper'

RSpec.describe Gitlab::Help::HugoTransformer, feature_category: :gitlab_docs do
  let(:transformer) { described_class.new }

  let(:details) do
    <<~MARKDOWN
      {{< details >}}

      - Tier: Free, Premium, Ultimate
      - Offering: GitLab.com, GitLab Self-Managed

      {{< /details >}}
    MARKDOWN
  end

  let(:history) do
    <<~MARKDOWN
      {{< history >}}

      - Introduced in GitLab 17.11

      {{< /history >}}
    MARKDOWN
  end

  it 'drops a details block instead of keeping its body' do
    content = "# Branches\n\n#{details}\nBranches keep your work apart.\n"

    expect(transformer.transform(content)).to eq("# Branches\n\nBranches keep your work apart.")
  end

  it 'leaves one inside a code fence alone' do
    content = "# Branches\n\n```markdown\n#{details}```\n"

    expect(transformer.transform(content)).to include('{{< details >}}', 'Tier: Free')
  end

  # Upstream turns this into a "Version history" heading, which the fork's help
  # typography renders as a banner above the page's own first line.
  it 'drops a history block rather than making a heading of it' do
    content = "# Service accounts\n\n#{history}\nUse a service account for automation.\n"

    expect(transformer.transform(content))
      .to eq("# Service accounts\n\nUse a service account for automation.")
  end

  # Upstream's generic handling, which the fork still wants everywhere else.
  it 'keeps the body of a paired shortcode it has no handler for' do
    content = "{{< something >}}\nkeep me\n{{< /something >}}\n"

    expect(transformer.transform(content)).to eq('keep me')
  end
end
