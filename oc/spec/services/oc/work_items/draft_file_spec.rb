# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OC::WorkItems::DraftFile, feature_category: :source_code_management do
  let(:uuid) { '11111111-2222-3333-4444-555555555555' }
  let(:path) { "#{uuid}/_incoming/fix-login.yml" }

  def parse(yaml, at: path)
    described_class.parse(yaml, path: at)
  end

  def error_from(yaml, at: path)
    parse(yaml, at: at)
    raise 'expected a DraftFile::Error, but the draft parsed'
  rescue described_class::Error => error
    error
  end

  describe '.draft_path?' do
    it 'accepts .yml and .yaml directly in the installation\'s _incoming' do
      expect(described_class.draft_path?("#{uuid}/_incoming/a.yml", uuid)).to be(true)
      expect(described_class.draft_path?("#{uuid}/_incoming/a.yaml", uuid)).to be(true)
    end

    it 'ignores other files, subdirectories, and other installations' do
      expect(described_class.draft_path?("#{uuid}/_incoming/README.md", uuid)).to be(false)
      expect(described_class.draft_path?("#{uuid}/_incoming/a.yml~", uuid)).to be(false)
      expect(described_class.draft_path?("#{uuid}/_incoming/sub/a.yml", uuid)).to be(false)
      expect(described_class.draft_path?("other/_incoming/a.yml", uuid)).to be(false)
      expect(described_class.draft_path?("#{uuid}/issues/1.yml", uuid)).to be(false)
    end
  end

  describe '.parse' do
    it 'reads every field' do
      draft = parse(<<~YAML)
        ---
        _schema: issue_draft@1
        title: Login fails after password reset
        description: |
          Probably #draft:session-cache.
        labels: [bug, auth]
        milestone: "17.4"
        assignees: [jane]
        due_date: 2026-12-01
        confidential: true
        type: task
        .note: mine
      YAML

      expect(draft).to have_attributes(
        key: 'fix-login', title: 'Login fails after password reset',
        description: "Probably #draft:session-cache.\n", labels: %w[bug auth], milestone: '17.4',
        assignees: %w[jane], due_date: Date.new(2026, 12, 1), confidential?: true, type: 'task')
    end

    it 'needs only a schema and a title, and defaults the rest' do
      draft = parse("_schema: issue_draft@1\ntitle: T\n")

      expect(draft).to have_attributes(labels: [], assignees: [], confidential?: false, type: 'issue',
        description: nil, milestone: nil, due_date: nil)
    end

    it 'takes its key from a .yaml filename too' do
      expect(parse("_schema: issue_draft@1\ntitle: T\n", at: "#{uuid}/_incoming/x-1.yaml").key).to eq('x-1')
    end

    using RSpec::Parameterized::TableSyntax

    where(:yaml, :line, :message) do
      "title: T\n" | 1 | 'no "_schema"'
      "_schema: sync@1\ntitle: T\n"                            | 1   | '"_schema" must be issue_draft@1'
      "_schema: issue_draft@1\n"                               | 1   | 'no "title"'
      "_schema: issue_draft@1\ntitle: \"\"\n"                  | 2   | '"title" is empty'
      "_schema: issue_draft@1\ntitle: [a]\n"                   | 2   | '"title" must be a single value'
      "_schema: issue_draft@1\ntitle: T\ntitel: x\n"           | 3   | 'unknown key "titel"'
      "_schema: issue_draft@1\n_extra: x\ntitle: T\n"          | 2   | 'unknown key "_extra"'
      "_schema: issue_draft@1\ntitle: T\ntitle: U\n"           | 3   | '"title" appears twice (already on line 2)'
      "_schema: issue_draft@1\ntitle: T\nlabels: bug\n"        | 3   | '"labels" must be a list'
      "_schema: issue_draft@1\ntitle: T\ndue_date: soon\n"     | 3   | '"due_date" must be a date'
      "_schema: issue_draft@1\ntitle: T\nconfidential: yes\n"  | 3   | '"confidential" must be true or false'
      "_schema: issue_draft@1\ntitle: T\nconfidential: 'true'\n" | 3 | '"confidential" must be true or false'
      "_schema: issue_draft@1\ntitle: T\ntype: epic\n"         | 3   | '"type" is "epic"; it must be one of'
      "_schema: issue_draft@1\ntitle: &t T\nmilestone: *t\n"   | 2   | 'anchors and aliases are not supported'
      "- a\n"                                                  | 1   | 'must be a mapping'
      "_schema: issue_draft@1\ntitle: [unclosed\n"             | 2   | 'did not find expected'
      ""                                                       | nil | 'is empty'
    end

    with_them do
      it 'refuses it, naming the file and line' do
        error = error_from(yaml)

        expect(error.message).to include(message)
        expect(error.path).to eq(path)
        expect(error.line).to eq(line)
        expect(error.message).to start_with(line ? "#{path}:#{line}:" : "#{path}:")
      end
    end

    it 'refuses a title over the length limit' do
      long = 'x' * (Issuable::TITLE_LENGTH_MAX + 1)

      expect(error_from("_schema: issue_draft@1\ntitle: #{long}\n").message).to include('longer than')
    end

    it 'refuses a multi-line title' do
      expect(error_from("_schema: issue_draft@1\ntitle: |\n  a\n  b\n").message).to include('one line')
    end

    it 'refuses a filename that is not a valid key' do
      error = error_from("_schema: issue_draft@1\ntitle: T\n", at: "#{uuid}/_incoming/Fix Login.yml")

      expect(error.message).to include('"Fix Login" is not a valid draft name')
    end
  end

  describe '.rewrite_references' do
    it 'replaces known keys outside code and leaves the rest' do
      text = "#draft:a, `#draft:a`, #draft:a-2, #draft:zz\n```\n#draft:a\n```"

      expect(described_class.rewrite_references(text, 'a' => 7, 'a-2' => 8))
        .to eq("#7, `#draft:a`, #8, #draft:zz\n```\n#draft:a\n```")
    end
  end

  describe '#draft_references' do
    def references(description)
      parse({ '_schema' => 'issue_draft@1', 'title' => 'T', 'description' => description }.to_yaml)
        .draft_references
    end

    it 'finds each key once' do
      expect(references('See #draft:a and #draft:b-2, again #draft:a.')).to eq(%w[a b-2])
    end

    it 'does not read a longer key as a shorter one' do
      expect(references('#draft:fix-login-2')).to eq(%w[fix-login-2])
    end

    it 'skips code spans and fenced blocks' do
      text = "Use `#draft:literal` like this:\n\n```\n#draft:fenced\n```\n\nreal #draft:x"

      expect(references(text)).to eq(%w[x])
    end

    it 'ignores a #draft: that is part of a word or path' do
      expect(references('docs#draft:a and x/#draft:b')).to eq([])
    end

    it 'is empty without a description' do
      expect(parse("_schema: issue_draft@1\ntitle: T\n").draft_references).to eq([])
    end
  end
end
