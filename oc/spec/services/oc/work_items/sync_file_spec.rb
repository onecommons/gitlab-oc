# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OC::WorkItems::SyncFile, feature_category: :source_code_management do
  let(:staging_uuid) { '11111111-2222-3333-4444-555555555555' }
  let(:prod_uuid) { '99999999-8888-7777-6666-555555555555' }

  # The shape the docs show: staging drains into production, production takes
  # what staging gives it and nothing else.
  let(:migration) do
    <<~YAML
      ---
      _schema: sync@1
      staging:
        uuid: #{staging_uuid}
        sync:
          prod:
            transfer: all
      prod:
        uuid: #{prod_uuid}
        sync:
          staging:
            import: transferred
            user_mapping: email
    YAML
  end

  def parse(yaml)
    described_class.parse(yaml)
  end

  def error_from(yaml)
    parse(yaml)
    raise 'expected a SyncFile::Error, but the file parsed'
  rescue described_class::Error => error
    error
  end

  describe '.parse' do
    it 'reads instance blocks and binds each name to its uuid' do
      file = parse(migration)

      expect(file.instances.keys).to contain_exactly('staging', 'prod')
      expect(file.instances['staging'].uuid).to eq(staging_uuid)
    end

    it 'treats an empty file as declaring nothing' do
      expect(parse('')).to be_empty
      expect(parse("---\n")).to be_empty
    end

    describe 'what an instance does' do
      let(:file) { parse(migration) }

      it 'reports who we import from, keyed by the directory name on the branch' do
        expect(file.imports(prod_uuid).keys).to eq([staging_uuid])
        expect(file.imports(prod_uuid)[staging_uuid]).to be_imports_transferred
      end

      it 'reports who we give items to' do
        expect(file.transfers_from(staging_uuid).keys).to eq([prod_uuid])
        expect(file.transfers_from(staging_uuid)[prod_uuid]).to be_transfers_all
      end

      # A transfer is declared by the side losing the item, so the receiver
      # never finds it under its own name.
      it 'reports who is giving items to us, read out of their block' do
        expect(file.transfers_to(prod_uuid).keys).to eq([staging_uuid])
      end

      it 'has the giver importing nothing and the receiver transferring nothing' do
        expect(file.imports(staging_uuid)).to be_empty
        expect(file.transfers_from(prod_uuid)).to be_empty
      end

      # Neither an error nor a special case: most instances named on a shared
      # branch are somebody else.
      it 'says nothing about an instance the file does not declare' do
        expect(file.instance_for('nobody')).to be_nil
        expect(file.imports('nobody')).to be_empty
        expect(file.transfers_to('nobody')).to be_empty
      end
    end

    describe 'transfer sets' do
      let(:available) { ['issues/1.yml', 'issues/2.yml', 'merge_requests/7.yml'] }

      it 'expands `all` against what the giver holds now, issues only' do
        pair = parse(migration).transfers_from(staging_uuid)[prod_uuid]

        expect(pair.transfer_paths(available)).to contain_exactly('issues/1.yml', 'issues/2.yml')
      end

      it 'takes a list as written' do
        file = parse(<<~YAML)
          ---
          _schema: sync@1
          staging:
            uuid: #{staging_uuid}
            sync:
              prod:
                transfer:
                  - issues/42.yml
          prod:
            uuid: #{prod_uuid}
            sync:
              staging:
                import: transferred
        YAML

        pair = file.transfers_from(staging_uuid)[prod_uuid]

        expect(pair).not_to be_transfers_all
        expect(pair.transfer_paths(available)).to eq(['issues/42.yml'])
      end
    end

    describe 'user_mapping and default_user' do
      def pair_with(*lines)
        parse(<<~YAML).imports(prod_uuid)[staging_uuid]
          ---
          _schema: sync@1
          staging:
            uuid: #{staging_uuid}
          prod:
            uuid: #{prod_uuid}
            sync:
              staging:
                import: all
          #{lines.map { |line| "      #{line}" }.join("\n")}
        YAML
      end

      it 'defaults to the email level, which is what the setting it replaced defaulted to' do
        expect(pair_with.trust).to eq(:email)
      end

      it 'takes the declared level' do
        expect(pair_with('user_mapping: username').trust).to eq(:username)
        expect(pair_with('user_mapping: none').trust).to eq(:none)
      end

      it 'treats an absent default_user and the ghost keyword alike' do
        expect(pair_with).to be_default_user_ghost
        expect(pair_with('default_user: <ghost>')).to be_default_user_ghost
      end

      it 'takes a username' do
        pair = pair_with('default_user: import-bot')

        expect(pair).not_to be_default_user_ghost
        expect(pair.default_user).to eq('import-bot')
      end
    end

    # YAML comments do not survive anything that rewrites a file, and a file two
    # teams edit needs somewhere to record why an entry is there.
    describe 'keys beginning with a dot' do
      it 'ignores them at every level' do
        file = parse(<<~YAML)
          ---
          _schema: sync@1
          .note: why this file exists
          staging:
            uuid: #{staging_uuid}
            .owner: platform team
            sync:
              prod:
                .ticket: OPS-1234
                transfer: all
          prod:
            uuid: #{prod_uuid}
            sync:
              staging:
                import: transferred
        YAML

        expect(file.instances.keys).to contain_exactly('staging', 'prod')
        expect(file.transfers_from(staging_uuid)[prod_uuid]).to be_transfers_all
      end
    end

    context 'with anchors and aliases' do
      # The reason a `.` key earns its place: it is where a shared block goes.
      let(:shared) do
        <<~YAML
          ---
          _schema: sync@1
          .common: &common
            import: all
            user_mapping: username
          staging:
            uuid: #{staging_uuid}
          prod:
            uuid: #{prod_uuid}
            sync:
              staging:
                <<: *common
                default_user: import-bot
        YAML
      end

      it 'merges the anchored block in' do
        pair = parse(shared).imports(prod_uuid)[staging_uuid]

        expect(pair.import).to eq('all')
        expect(pair.trust).to eq(:username)
        expect(pair.default_user).to eq('import-bot')
      end

      it 'lets a key written out win over a merged one' do
        yaml = <<~YAML
          ---
          _schema: sync@1
          .common: &common
            import: all
          staging:
            uuid: #{staging_uuid}
          prod:
            uuid: #{prod_uuid}
            sync:
              staging:
                <<: *common
                import: transferred
        YAML

        expect(parse(yaml).imports(prod_uuid)[staging_uuid]).to be_imports_transferred
      end

      it 'takes a whole section as an alias' do
        yaml = <<~YAML
          ---
          _schema: sync@1
          .common: &common
            import: all
          staging:
            uuid: #{staging_uuid}
          prod:
            uuid: #{prod_uuid}
            sync:
              staging: *common
        YAML

        expect(parse(yaml).imports(prod_uuid)[staging_uuid]).to be_imports_all
      end

      it 'validates a merged key as though it were written out' do
        yaml = shared.sub('import: all', 'improt: all')

        expect(error_from(yaml).message).to include('"improt"')
      end

      it 'refuses an alias with no anchor' do
        yaml = "---\n_schema: sync@1\nstaging:\n  uuid: x\n  sync: *nothing\n"

        expect(error_from(yaml).message).to include('no anchor named "&nothing"')
      end

      it 'refuses the same anchor defined twice' do
        yaml = shared.sub('staging:', "other: &common\n  uuid: z\nstaging:")

        expect(error_from(yaml).message).to include('defined twice')
      end

      it 'refuses an anchor that merges itself' do
        yaml = "---\n_schema: sync@1\na: &loop\n  <<: *loop\n  uuid: x\n"

        expect(error_from(yaml).message).to include('nested too deeply')
      end

      # An alias may be repeated, so depth alone does not bound the work: five
      # levels of ten repeats is 10^5 expansions of a file a few hundred bytes
      # long, and this runs on the push path.
      it 'refuses a merge that expands out of proportion to the file' do
        yaml = +"---\n_schema: sync@1\n.a0: &a0\n  import: all\n"

        (1..5).each do |level|
          yaml << ".a#{level}: &a#{level}\n  <<: [#{(["*a#{level - 1}"] * 10).join(', ')}]\n"
        end

        yaml << "a:\n  uuid: x\n  <<: *a5\n"

        expect(yaml.bytesize).to be < 1.kilobyte
        expect(error_from(yaml).message).to include('expands to too much')
      end
    end
  end

  describe '.parse rejections' do
    # Every one of these reaches a person: the push-time check runs this parser
    # and reports what it says.
    it 'reports a YAML syntax error with its line' do
      error = error_from("---\n_schema: sync@1\nstaging: %broken\n")

      expect(error.line).to eq(3)
      expect(error.message).to start_with('sync.yml:3:')
    end

    it 'refuses a file with no _schema' do
      expect(error_from("---\nstaging:\n  uuid: x\n").message).to include('no "_schema"')
    end

    it 'refuses a schema this build does not understand' do
      expect(error_from("---\n_schema: sync@2\n").message).to include('sync@2')
    end

    it 'refuses an unknown reserved key, and points at the dot prefix instead' do
      error = error_from("---\n_schema: sync@1\n_owner: platform\n")

      expect(error.line).to eq(3)
      expect(error.message).to include('_owner').and include('"." prefix')
    end

    it 'refuses an instance with no uuid' do
      expect(error_from("---\n_schema: sync@1\nstaging:\n  sync: {}\n").message)
        .to include('has no "uuid"')
    end

    it 'refuses two instances sharing a uuid' do
      yaml = "---\n_schema: sync@1\na:\n  uuid: same\nb:\n  uuid: same\n"

      expect(error_from(yaml).message).to include('same "uuid"')
    end

    # Last-wins in every YAML loader, which here means an edit that appears to
    # have been made and was not.
    it 'refuses a duplicate key rather than taking the last one' do
      yaml = "---\n_schema: sync@1\nstaging:\n  uuid: one\n  uuid: two\n"
      error = error_from(yaml)

      expect(error.message).to include('twice').and include('line 4')
    end

    it 'refuses a sync naming an instance the file does not declare' do
      yaml = "---\n_schema: sync@1\nstaging:\n  uuid: x\n  sync:\n    ghost_town:\n      import: all\n"

      expect(error_from(yaml).message).to include('does not declare')
    end

    it 'refuses an instance syncing with itself' do
      yaml = "---\n_schema: sync@1\nstaging:\n  uuid: x\n  sync:\n    staging:\n      import: all\n"

      expect(error_from(yaml).message).to include('cannot sync with itself')
    end

    it 'refuses an unknown key in an instance block' do
      expect(error_from("---\n_schema: sync@1\nstaging:\n  uuid: x\n  improt: all\n").message)
        .to include('"improt"')
    end

    it 'refuses an unknown key in a sync block' do
      yaml = <<~YAML
        ---
        _schema: sync@1
        staging:
          uuid: #{staging_uuid}
        prod:
          uuid: #{prod_uuid}
          sync:
            staging:
              improt: all
      YAML

      expect(error_from(yaml).message).to include('"improt"').and include('"prod/sync/staging"')
    end

    it 'refuses an import mode and a user_mapping level it does not know' do
      base = "---\n_schema: sync@1\na:\n  uuid: 1\nb:\n  uuid: 2\n  sync:\n    a:\n      "

      expect(error_from("#{base}import: some\n").message).to include('"all", "transferred"')
      expect(error_from("#{base}user_mapping: sometimes\n").message)
        .to include('"none", "email", "username"')
    end

    # The cross-reference constraint: a transfer the receiving side has not
    # agreed to import freezes items on one instance that never appear on the
    # other.
    it 'refuses a transfer the receiving side declares no import for' do
      yaml = <<~YAML
        ---
        _schema: sync@1
        staging:
          uuid: #{staging_uuid}
          sync:
            prod:
              transfer: all
        prod:
          uuid: #{prod_uuid}
      YAML

      expect(error_from(yaml).message).to include('declares no "import"')
    end

    it 'refuses the same item being given to two instances' do
      yaml = <<~YAML
        ---
        _schema: sync@1
        a:
          uuid: 1
          sync:
            b:
              transfer:
                - issues/42.yml
            c:
              transfer:
                - issues/42.yml
        b:
          uuid: 2
          sync:
            a:
              import: transferred
        c:
          uuid: 3
          sync:
            a:
              import: transferred
      YAML

      expect(error_from(yaml).message).to include('issues/42.yml').and include('both')
    end

    it 'refuses transferring everything to one instance and items to another' do
      yaml = <<~YAML
        ---
        _schema: sync@1
        a:
          uuid: 1
          sync:
            b:
              transfer: all
            c:
              transfer:
                - issues/42.yml
        b:
          uuid: 2
          sync:
            a:
              import: transferred
        c:
          uuid: 3
          sync:
            a:
              import: transferred
      YAML

      expect(error_from(yaml).message).to include('everything')
    end

    it 'refuses a merge request in a transfer list, which v1 cannot carry' do
      yaml = <<~YAML
        ---
        _schema: sync@1
        a:
          uuid: 1
          sync:
            b:
              transfer:
                - merge_requests/7.yml
        b:
          uuid: 2
          sync:
            a:
              import: transferred
      YAML

      expect(error_from(yaml).message).to include('merge requests cannot be transferred')
    end

    it 'refuses a transfer entry that is not a path in the giver own directory' do
      yaml = <<~YAML
        ---
        _schema: sync@1
        a:
          uuid: 1
          sync:
            b:
              transfer:
                - #{staging_uuid}/issues/7.yml
        b:
          uuid: 2
          sync:
            a:
              import: transferred
      YAML

      expect(error_from(yaml).message).to include('issues/42.yml')
    end

    it 'refuses a default_user that could not be a username' do
      base = "---\n_schema: sync@1\na:\n  uuid: 1\nb:\n  uuid: 2\n  sync:\n    a:\n      "

      expect(error_from("#{base}default_user: not a username\n").message)
        .to include('not a valid username')
      expect(error_from("#{base}default_user: <nobody>\n").message)
        .to include('unknown "default_user" keyword')
    end
  end

  # A run cannot ask anybody anything, so a file it cannot read means the same
  # as a file that declares nothing: import nothing. The push that introduced
  # the problem was refused at the time.
  describe '.load' do
    it 'parses a good file' do
      expect(described_class.load(migration).instances.keys).to contain_exactly('staging', 'prod')
    end

    it 'declares nothing for a file it cannot read, and says so in the log' do
      expect(::Gitlab::AppLogger).to receive(:warn).with(hash_including(::Labkit::Fields::ERROR_MESSAGE))

      expect(described_class.load("---\n_schema: nope\n")).to be_empty
    end

    it 'declares nothing for a missing file' do
      expect(described_class.load(nil)).to be_empty
    end
  end
end
