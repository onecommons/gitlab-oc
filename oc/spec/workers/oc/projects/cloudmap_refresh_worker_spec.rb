# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OC::Projects::CloudmapRefreshWorker, :clean_gitlab_redis_shared_state, feature_category: :source_code_management do
  let_it_be(:group) { create(:group, :public) }
  let_it_be(:blueprint) { create(:project, :public, namespace: group) }
  let_it_be(:dashboard) { create(:project, :public, namespace: group) }
  let_it_be(:private_blueprint) { create(:project, :private, namespace: group) }
  let_it_be(:untyped) { create(:project, :public, namespace: group) }
  let_it_be(:regular) { create(:project, :public, namespace: group) }

  let(:server) { 'http://unfurl.test' }
  let(:analyze_url) { "#{server}/cloudmap/analyze?auth_project=#{CGI.escape(OC::UNFURL_CLOUDMAP_PROJECT)}" }
  let(:cursor_key) { described_class::CURSOR_KEY }

  subject(:perform) { described_class.new.perform }

  before_all do
    blueprint.record_unfurl_type!(OC::UNFURL_BLUEPRINT)
    dashboard.record_unfurl_type!(OC::UNFURL_DASHBOARD)
    private_blueprint.record_unfurl_type!(OC::UNFURL_BLUEPRINT)
    regular.record_unfurl_type!(OC::REGULAR_PROJECT)
  end

  before do
    # Rows the unfurl_type setup wrote; each example writes its own.
    OC::Projects::CloudmapEvent.delete_all
    allow(OC::Repositories::UnfurlServer).to receive(:internal_url).and_return(server)
  end

  def row(project, kind: :metadata_changed, payload: {}, occurred_at: 1.minute.ago)
    create(:oc_cloudmap_event, project: project, kind: kind, payload: payload, occurred_at: occurred_at)
  end

  def group_row(kind, project_ids, path: group.full_path, **payload)
    create(:oc_cloudmap_event, project: nil, organization_id: group.organization_id, project_path: path,
      kind: kind, occurred_at: 1.minute.ago, payload: { project_ids: project_ids, **payload })
  end

  def cursor
    Gitlab::Redis::SharedState.with { |redis| redis.get(cursor_key) }&.to_i
  end

  # Filled in as requests are made.
  def sent_bodies
    bodies = []
    stub_request(:post, analyze_url).with { |request| bodies << Gitlab::Json::SafeParser.parse(request.body) }
    bodies
  end

  def url_for(path)
    Gitlab::RepositoryUrlBuilder.build(path, protocol: :http)
  end

  describe 'add' do
    it 'sends only public blueprints and dashboards, in one request' do
      bodies = sent_bodies
      [blueprint, dashboard, private_blueprint, untyped, regular].each { |project| row(project) }

      perform

      expect(bodies.size).to eq(1)
      expect(bodies.first['analyze']).to eq('metadata')
      expect(bodies.first['add']).to match_array([blueprint.http_url_to_repo, dashboard.http_url_to_repo])
      expect(cursor).to eq(OC::Projects::CloudmapEvent.maximum(:id))
    end

    it 'sends a project once however many rows name it' do
      bodies = sent_bodies
      row(blueprint)
      row(blueprint, kind: :visibility_changed)

      perform

      expect(bodies.first['add']).to eq([blueprint.http_url_to_repo])
    end

    where(:kind) { %i[namespace_moved group_archived group_unarchived] }

    with_them do
      it 'sends the projects a group row lists' do
        bodies = sent_bodies
        group_row(kind, [blueprint.id, untyped.id], old_path: group.full_path)

        perform

        expect(bodies.first['add']).to eq([blueprint.http_url_to_repo])
      end
    end
  end

  describe 'private' do
    it 'reports a blueprint that is no longer public' do
      bodies = sent_bodies
      row(private_blueprint, kind: :visibility_changed)

      perform

      expect(bodies.first).to include('add' => [], 'private' => [private_blueprint.http_url_to_repo])
    end

    it 'says nothing of a project that was never a blueprint or dashboard' do
      row(create(:project, :private, namespace: group), kind: :visibility_changed)

      perform

      expect(WebMock).not_to have_requested(:post, analyze_url)
    end
  end

  describe 'deleted' do
    def tombstone(path, visibility)
      create(:oc_cloudmap_event, project: nil, kind: :project_deleted, project_path: path,
        organization_id: group.organization_id, occurred_at: 1.minute.ago, payload: { visibility: visibility })
    end

    it 'reports a repository that was public, by the path it had' do
      bodies = sent_bodies
      tombstone('group/gone', 'public')

      perform

      expect(bodies.first).to include('add' => [], 'deleted' => [url_for('group/gone')])
    end

    it 'says nothing of one that was never public' do
      tombstone('group/secret', 'private')

      perform

      expect(WebMock).not_to have_requested(:post, analyze_url)
    end
  end

  describe 'moved' do
    it 'reports a project rename from the old path to the new' do
      bodies = sent_bodies
      row(blueprint, payload: { changed: %w[path], old_path: "#{group.full_path}/old-name" })

      perform

      expect(bodies.first['moved']).to eq([
        { 'from' => url_for("#{group.full_path}/old-name"), 'to' => blueprint.http_url_to_repo }
      ])
      expect(bodies.first['add']).to eq([blueprint.http_url_to_repo])
    end

    # The row carries the namespace's old path; each project's is derived.
    it 'reports each project under a moved namespace' do
      bodies = sent_bodies
      group_row(:namespace_moved, [blueprint.id, dashboard.id], old_path: 'old-group')

      perform

      expect(bodies.first['moved']).to match_array([
        { 'from' => url_for("old-group/#{blueprint.path}"), 'to' => blueprint.http_url_to_repo },
        { 'from' => url_for("old-group/#{dashboard.path}"), 'to' => dashboard.http_url_to_repo }
      ])
    end

    it 'does not report an archive as a move' do
      bodies = sent_bodies
      group_row(:group_archived, [blueprint.id])

      perform

      expect(bodies.first).not_to have_key('moved')
    end
  end

  describe 'the cursor' do
    it 'reads past rows it has nothing to send for' do
      last = row(blueprint, kind: :pipeline_finished)

      perform

      expect(WebMock).not_to have_requested(:post, analyze_url)
      expect(cursor).to eq(last.id)
    end

    it 'starts after the stored cursor' do
      bodies = sent_bodies
      row(blueprint)
      later = row(dashboard)
      Gitlab::Redis::SharedState.with { |redis| redis.set(cursor_key, later.id - 1) }

      perform

      expect(bodies.first['add']).to eq([dashboard.http_url_to_repo])
    end

    # An id is assigned before its row commits, so the newest rows wait.
    it 'stops at the first row too new to read, keeping the order' do
      bodies = sent_bodies
      first = row(blueprint)
      row(dashboard, occurred_at: Time.current)
      row(blueprint, occurred_at: 1.minute.ago)

      perform

      expect(bodies.first['add']).to eq([blueprint.http_url_to_repo])
      expect(cursor).to eq(first.id)
    end

    it 'keeps its place when the server refuses a request' do
      stub_request(:post, analyze_url).to_return(status: 500)
      row(blueprint)

      perform

      expect(cursor).to be_nil
    end

    it 'keeps its place when the server cannot be reached' do
      stub_request(:post, analyze_url).to_raise(Errno::ECONNREFUSED)
      row(blueprint)

      perform

      expect(cursor).to be_nil
    end

    it 'reads nothing when no server is configured' do
      allow(OC::Repositories::UnfurlServer).to receive(:internal_url).and_return(nil)
      row(blueprint)

      perform

      expect(WebMock).not_to have_requested(:post, analyze_url)
      expect(cursor).to be_nil
    end

    # Losing the cursor costs a replay of INITIAL_WINDOW, not everything.
    it 'starts from INITIAL_WINDOW when it has none' do
      bodies = sent_bodies
      row(dashboard, occurred_at: 2.days.ago)
      row(blueprint)

      perform

      expect(bodies.first['add']).to eq([blueprint.http_url_to_repo])
    end
  end

  it 'splits a large batch across requests' do
    stub_const("#{described_class}::EVENTS_PER_REQUEST", 1)
    bodies = sent_bodies
    row(blueprint)
    row(private_blueprint, kind: :visibility_changed)

    perform

    expect(bodies.size).to eq(2)
  end
end
