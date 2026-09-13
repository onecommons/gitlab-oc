# frozen_string_literal: true

module QA
  # Work items sync against a running installation, driven the way a person
  # drives it: real API calls, and a real `git push` whose output is read back.
  #
  # The in-process specs simulate two installations by stubbing the instance
  # uuid, which covers the logic and cannot cover the plumbing. Three things
  # only exist out here:
  #
  # * the pre-receive rejection actually reaching a git client, with Gitaly's
  #   prefix on it and git's in front of that;
  # * the message a successful push prints back;
  # * the whole worker chain -- push, PostReceive, ImportWorker, SyncWorker --
  #   running for real, in order, on its own.
  #
  # The peer is synthetic: its directory is a few files written by hand. That
  # is not a shortcut around a second installation, it is what a peer *is* --
  # every instance's directory is exactly the files it has committed, and
  # nothing about reading one involves the installation that wrote it. What a
  # second installation would add is the writing side, which the publishing
  # example below already covers from this end.
  RSpec.describe 'OneCommons work items sync', feature_category: :source_code_management do
    let(:branch) { 'gitlab-work-items' }
    let(:peer_uuid) { '11111111-2222-3333-4444-555555555555' }
    let(:api_client) { Runtime::API::Client.as_admin }

    let(:project) do
      create(:project, :with_readme, name: "work-items-sync-#{SecureRandom.hex(4)}", api_client: api_client)
    end

    let(:issue) { create(:issue, project: project, title: 'Published by the sync', api_client: api_client) }

    def api(path)
      Runtime::API::Request.new(api_client, path).url
    end

    def enable_sync
      response = Support::API.post(api("#{project.api_get_path}/work_items_sync"), enabled: true)

      expect(response.code).to eq(Support::API::HTTP_STATUS_OK)
    end

    def tree(path = nil)
      query = { ref: branch, per_page: 100 }
      query[:path] = path if path
      url = api("#{project.api_get_path}/repository/tree?#{URI.encode_www_form(query)}")
      response = Support::API.get(url)

      return [] unless response.code == Support::API::HTTP_STATUS_OK

      Support::API.parse_body(response)
    end

    def file_on_branch(path)
      encoded = ERB::Util.url_encode(path)
      response = Support::API.get(api("#{project.api_get_path}/repository/files/#{encoded}/raw?ref=#{branch}"))

      response.code == Support::API::HTTP_STATUS_OK ? response.body : nil
    end

    # This installation's uuid is not exposed by any API, but the branch is
    # named after it: the one directory the sync writes is it.
    def instance_uuid
      @instance_uuid ||= begin
        entry = tree.find { |item| item[:type] == 'tree' }
        raise 'the sync has not written a directory yet' unless entry

        entry[:name]
      end
    end

    def wait_for_branch
      Support::Waiter.wait_until(max_duration: 90, sleep_interval: 1, raise_on_failure: true,
        message: 'the sync branch to be written') do
        tree.any? { |item| item[:type] == 'tree' }
      end
    end

    def issue_writable?
      response = Support::API.put(api("#{project.api_get_path}/issues/#{issue.iid}"),
        title: "Edited at #{SecureRandom.hex(4)}")

      response.code == Support::API::HTTP_STATUS_OK
    end

    # Pushes files onto the sync branch and hands back everything git printed,
    # which is where the messages under test appear.
    def push(files, message: 'peer push')
      Git::Repository.perform do |repository|
        repository.uri = project.repository_http_location.uri

        # The token rather than use_default_credentials: that reads a password
        # this suite is never given, and without one no netrc is written at
        # all, so git asks for a password nobody is there to type.
        repository.username = Runtime::User::Store.admin_user.username
        repository.password = api_client.personal_access_token

        repository.clone
        repository.configure_identity('GitLab QA', 'root@gitlab.com')
        repository.checkout(branch)

        files.each { |path, content| repository.add_file(path, content) }
        repository.commit(message)
        repository.push_changes(branch)
      end
    end

    def peer_document(iid:, title:, transferred_from: nil)
      <<~YAML
        ---
        _schema: issues@1
        title: #{title}
        description: Written by hand, standing in for another installation.
        author_id: 12
        project_id: 99
        iid: #{iid}
        state: opened
        confidential: false
        created_at: '2026-03-14T09:00:00.000Z'
        updated_at: '2026-03-14T09:00:00.000Z'
        web_url: https://peer.example.com/group/project/-/issues/#{iid}
        #{"transferred_from: #{transferred_from}" if transferred_from}
      YAML
    end

    def peer_identities
      <<~YAML
        ---
        _schema: ids@1
        projects:
          99: group/project
        users:
          12:
            username: remote-author
            name: Remote Author
      YAML
    end

    def sync_file(here_sync: nil, peer_sync: nil)
      <<~YAML
        ---
        _schema: sync@1
        here:
          uuid: #{instance_uuid}
        #{here_sync}
        peer:
          uuid: #{peer_uuid}
        #{peer_sync}
      YAML
    end

    # API only: the screenshot the framework takes on failure would start a
    # browser to photograph nothing. capybara-screenshot hooks in through
    # RSpec.configure, so its after(:each) runs *after* a group-level one --
    # restoring the flag there would be too late. Context scope brackets both.
    before(:context) do
      Capybara::Screenshot.autosave_on_failure = false
    end

    after(:context) do
      Capybara::Screenshot.autosave_on_failure = true
    end

    before do
      enable_sync
      issue
      wait_for_branch
    end

    it 'publishes this project own items onto the branch',
      :requires_admin do
      document = nil

      Support::Waiter.wait_until(max_duration: 90, sleep_interval: 1, raise_on_failure: true) do
        document = file_on_branch("#{instance_uuid}/issues/#{issue.iid}.yml")
      end

      expect(document).to include('_schema: issues@1')
      expect(document).to include(issue.title)
    end

    # The whole point of coming out here. Everything below the check -- the
    # internal API answering 401 rather than 403, Gitaly prefixing the message,
    # git printing it -- only happens for real.
    it 'refuses a push that breaks sync.yml, and says why to whoever pushed',
      :requires_admin do
      broken = sync_file(peer_sync: "  sync:\n    here:\n      improt: all")

      expect { push({ 'sync.yml' => broken }, message: 'break the control file') }
        .to raise_error(Support::Run::CommandError, /Work items sync: sync\.yml:\d+: unknown key "improt"/)
    end

    it 'tells a successful push what the file it accepted means',
      :requires_admin do
      declared = sync_file(here_sync: "  sync:\n    peer:\n      import: all")

      output = push({ 'sync.yml' => declared }, message: 'declare an import')

      expect(output).to include('Work items sync: sync.yml updated')
      expect(output).to include("This instance is 'here'")
      expect(output).to include('imports all from peer')
    end

    it 'imports a declared peer items, read-only',
      :requires_admin do
      push({
        'sync.yml' => sync_file(here_sync: "  sync:\n    peer:\n      import: all"),
        "#{peer_uuid}/ids.yml" => peer_identities,
        "#{peer_uuid}/issues/1.yml" => peer_document(iid: 1, title: 'Theirs, mirrored here')
      }, message: 'import from a peer')

      imported = nil

      # Listed and matched here rather than asked for with `search=`, which
      # this installation answers with nothing for a title that plainly
      # matches. Whatever that is about, it is not what this example is for.
      Support::Waiter.wait_until(max_duration: 120, sleep_interval: 1, raise_on_failure: true,
        message: 'the peer item to be imported') do
        response = Support::API.get(api("#{project.api_get_path}/issues"))
        imported = Support::API.parse_body(response)
          .find { |item| item[:title] == 'Theirs, mirrored here' }
      end

      expect(imported[:title]).to eq('Theirs, mirrored here')

      response = Support::API.put(api("#{project.api_get_path}/issues/#{imported[:iid]}"),
        title: 'Editing somebody else item')

      expect(response.code).to eq(403)
    end

    # Both halves of a transfer from the side that gives one away: the freeze
    # that closes the edit window straight away, and the letting-go once the
    # other installation has published what it took.
    it 'hands an item over, and takes back a copy of it under the same number',
      :requires_admin do
      transfer = sync_file(
        here_sync: "  sync:\n    peer:\n      transfer:\n        - issues/#{issue.iid}.yml",
        peer_sync: "  sync:\n    here:\n      import: transferred")

      push({ 'sync.yml' => transfer }, message: 'promise it away')

      Support::Waiter.wait_until(max_duration: 120, sleep_interval: 1, raise_on_failure: true,
        message: 'the promised item to be frozen') do
        !issue_writable?
      end

      # What the other installation would publish once it had taken the item.
      push({
        "#{peer_uuid}/ids.yml" => peer_identities,
        "#{peer_uuid}/issues/7.yml" => peer_document(
          iid: 7, title: 'Theirs now',
          transferred_from: "#{instance_uuid}/issues/#{issue.iid}.yml")
      }, message: 'the new owner publishes it')

      Support::Waiter.wait_until(max_duration: 120, sleep_interval: 1, raise_on_failure: true,
        message: 'the item to be let go of') do
        response = Support::API.get(api("#{project.api_get_path}/issues/#{issue.iid}"))

        Support::API.parse_body(response)[:title] == 'Theirs now'
      end

      # The number it always had, so every link ever written to it still
      # resolves -- and still not ours to edit.
      expect(issue_writable?).to be(false)

      # And our own directory now points at theirs instead of holding it.
      Support::Waiter.wait_until(max_duration: 90, sleep_interval: 1, raise_on_failure: true,
        message: 'the pointer to replace the document') do
        file_on_branch("#{instance_uuid}/issues/#{issue.iid}.yml")&.include?('issue_reference@1')
      end

      # A copy rather than a snapshot: what we are left with goes on following
      # the instance that took it, through the machinery every other copy uses.
      push({
        "#{peer_uuid}/issues/7.yml" => peer_document(
          iid: 7, title: 'Theirs now, and edited',
          transferred_from: "#{instance_uuid}/issues/#{issue.iid}.yml")
      }, message: 'the new owner edits it')

      Support::Waiter.wait_until(max_duration: 120, sleep_interval: 1, raise_on_failure: true,
        message: 'the new owner edit to reach our copy') do
        response = Support::API.get(api("#{project.api_get_path}/issues/#{issue.iid}"))

        Support::API.parse_body(response)[:title] == 'Theirs now, and edited'
      end
    end

    # The other direction, which one installation can still exercise because
    # the giving side of a transfer is entirely files: a peer declares it is
    # handing us an item, and this installation takes ownership of it.
    it 'takes an item a peer hands over, and publishes it as its own',
      :requires_admin do
      handover = sync_file(
        here_sync: "  sync:\n    peer:\n      import: transferred",
        peer_sync: "  sync:\n    here:\n      transfer:\n        - issues/1.yml")

      push({
        'sync.yml' => handover,
        "#{peer_uuid}/ids.yml" => peer_identities,
        "#{peer_uuid}/issues/1.yml" => peer_document(iid: 1, title: 'Handed to us')
      }, message: 'a peer hands an item over')

      taken = nil

      Support::Waiter.wait_until(max_duration: 120, sleep_interval: 1, raise_on_failure: true,
        message: 'the handed-over item to arrive') do
        response = Support::API.get(api("#{project.api_get_path}/issues"))
        taken = Support::API.parse_body(response).find { |item| item[:title] == 'Handed to us' }
      end

      # Published from our own directory as a document rather than a pointer,
      # stamped with where it came from -- which is the whole of what tells the
      # instance that gave it to us that it may let go.
      document = nil

      Support::Waiter.wait_until(max_duration: 120, sleep_interval: 1, raise_on_failure: true,
        message: 'our own document for it to be published') do
        document = file_on_branch("#{instance_uuid}/issues/#{taken[:iid]}.yml")
        document&.include?('transferred_from')
      end

      expect(document).to include('_schema: issues@1')
      expect(document).to include("transferred_from: #{peer_uuid}/issues/1.yml")

      # Ours now, and editable -- the point of taking it.
      response = Support::API.put(
        api("#{project.api_get_path}/issues/#{taken[:iid]}"), title: 'Ours to change')

      expect(response.code).to eq(Support::API::HTTP_STATUS_OK)

      # And the ratchet: a standing declaration of ours that names it must not
      # hand it back. This is the case a path-keyed check would miss, because
      # the row is filed under the path it came *from*.
      giving_back = sync_file(
        here_sync: "  sync:\n    peer:\n      import: transferred\n      transfer: all",
        peer_sync: "  sync:\n    here:\n      transfer:\n        - issues/1.yml\n      import: all")

      push({ 'sync.yml' => giving_back }, message: 'declare that we give everything back')

      # That declaration names our own item too, and ours is not one we were
      # given -- so it freezes. Waiting for that is what proves the freeze
      # phase ran at all, and it is the only honest way to then say the other
      # item was passed over: without a positive signal, testing that
      # something did *not* happen means waiting out a timeout, which costs a
      # minute and proves nothing except that a minute passed.
      Support::Waiter.wait_until(max_duration: 120, sleep_interval: 1, raise_on_failure: true,
        message: 'our own item to be frozen by the same declaration') do
        !issue_writable?
      end

      response = Support::API.put(
        api("#{project.api_get_path}/issues/#{taken[:iid]}"), title: 'Still ours')

      expect(response.code).to eq(Support::API::HTTP_STATUS_OK)
    end
  end
end
