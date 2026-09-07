# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OC::WorkItems::ReferenceRewriter, feature_category: :source_code_management do
  let_it_be(:project) { create(:project) }

  let(:peer) { '11111111-2222-3333-4444-555555555555' }
  let(:source_web_url) { 'https://peer.example.com/group/project/-/issues/42' }
  let(:rewriter) do
    described_class.new(project,
      source_instance_uuid: peer,
      source_web_url: source_web_url,
      source_origin: 'https://peer.example.com')
  end

  def replicate(relation, source_iid, record: nil, web_url: nil)
    create(:oc_replicated_work_item,
      project: project,
      source_instance_uuid: peer,
      source_path: "#{peer}/#{relation}/#{source_iid}.yml",
      source_iid: source_iid,
      source_web_url: web_url,
      source_kind: relation == 'issues' ? :issue : :merge_request,
      issue: relation == 'issues' ? record : nil,
      merge_request: relation == 'issues' ? nil : record)
  end

  describe 'a reference to something imported here' do
    it 'points at the local number' do
      local = create(:issue, project: project)
      replicate('issues', 20, record: local)

      expect(rewriter.rewrite('blocked by #20')).to eq("blocked by ##{local.iid}")
      expect(rewriter.unresolved).to be_empty
    end

    # The interesting case, and the reason rewriting exists at all: the local
    # number differs from the source's because something local already held it.
    it 'points at the local number even when it differs from the source' do
      local = create(:issue, project: project)
      local.update_columns(iid: 137)
      replicate('issues', 20, record: local)

      expect(rewriter.rewrite('blocked by #20')).to eq('blocked by #137')
    end

    it 'handles merge requests' do
      local = create(:merge_request, source_project: project, target_project: project)
      replicate('merge_requests', 3, record: local)

      expect(rewriter.rewrite('see !3')).to eq("see !#{local.iid}")
    end
  end

  describe 'a reference to something that is not here' do
    # Wrong is worse than broken. Left alone, #20 renders as a link to *our*
    # issue 20 -- a different item, with a different title, silently.
    it 'links back to the source instance' do
      expect(rewriter.rewrite('blocked by #20')).to eq(
        'blocked by [#20](https://peer.example.com/group/project/-/issues/20)')
      expect(rewriter.unresolved).to eq([20])
    end

    it 'uses the URL the row already recorded when there is a row' do
      replicate('issues', 20, web_url: 'https://peer.example.com/group/project/-/issues/20')

      expect(rewriter.rewrite('blocked by #20')).to include(
        '(https://peer.example.com/group/project/-/issues/20)')
      expect(rewriter.unresolved).to eq([20])
    end

    # A link to nowhere is worse than a number a reader can ask about.
    it 'leaves the reference alone when the source host is unknown' do
      bare = described_class.new(project, source_instance_uuid: peer)

      expect(bare.rewrite('blocked by #20')).to eq('blocked by #20')
    end
  end

  # #1 inside a code block is not a reference, and rewriting it corrupts
  # content that is often the very thing being discussed.
  describe 'code' do
    it 'leaves a fenced block alone' do
      text = "before #20\n\n```ruby\n# issue #20 in a comment\nputs '#20'\n```\n\nafter #20"

      result = rewriter.rewrite(text)

      expect(result).to include("# issue #20 in a comment")
      expect(result).to include("puts '#20'")
      expect(result.scan('[#20](').length).to eq(2)
    end

    it 'leaves a tilde fence alone' do
      expect(rewriter.rewrite("~~~\n#20\n~~~")).to eq("~~~\n#20\n~~~")
    end

    it 'leaves an inline code span alone' do
      expect(rewriter.rewrite('use `#20` here')).to eq('use `#20` here')
    end
  end

  describe 'things that only look like references' do
    it 'ignores a number joined to a word' do
      expect(rewriter.rewrite('abc#20')).to eq('abc#20')
    end

    it 'ignores a heading' do
      expect(rewriter.rewrite('# Heading')).to eq('# Heading')
    end

    it 'ignores a colour' do
      expect(rewriter.rewrite('#ff0000')).to eq('#ff0000')
    end

    # A username cannot end in punctuation upstream either, and swallowing the
    # sentence's full stop would put it inside the link and point at a profile
    # that does not exist.
    it 'stops a mention at the end of a sentence' do
      expect(rewriter.rewrite('ask @jane.')).to eq(
        'ask [@jane](https://peer.example.com/jane).')
    end

    it 'keeps a dot inside a username' do
      expect(rewriter.rewrite('ask @jane.doe today')).to include('[@jane.doe](')
    end

    it 'ignores an empty or missing body' do
      expect(rewriter.rewrite(nil)).to be_nil
      expect(rewriter.rewrite('')).to eq('')
    end
  end

  it 'reports every source iid it could not place, once each' do
    rewriter.rewrite('#20 and #21 and #20 again')

    expect(rewriter.unresolved.uniq).to contain_exactly(20, 21)
  end
end
