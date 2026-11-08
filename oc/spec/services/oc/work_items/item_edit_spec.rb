# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OC::WorkItems::ItemEdit, feature_category: :source_code_management do
  let(:uuid) { '11111111-2222-3333-4444-555555555555' }
  let(:path) { "#{uuid}/issues/42.yml" }

  let(:comment) do
    { 'note' => 'First', 'author_id' => 7, 'created_at' => '2026-01-02T03:04:05.000Z',
      'discussion_id' => 'abc', 'system' => false }
  end

  let(:original) do
    {
      '_schema' => 'issues@1', 'title' => 'Old', 'author_id' => 7, 'iid' => 42, 'state' => 'opened',
      'description' => 'Text', 'confidential' => false, 'due_date' => '2026-12-01',
      'label_links' => [{ 'target_type' => 'Issue', 'label' => { 'title' => 'bug', 'color' => '#f00' } }],
      'milestone' => { 'title' => '1.0', 'state' => 'active' },
      'notes' => [comment]
    }
  end

  def diff(after, old = original)
    described_class.diff(path: path, old_yaml: old.to_yaml, new_yaml: after.is_a?(String) ? after : after.to_yaml)
  end

  def error_for(after)
    diff(after)
    raise 'expected an ItemEdit::Error'
  rescue described_class::Error => error
    error.message
  end

  describe '.item_path?' do
    it 'accepts issue files in the installation directory only' do
      expect(described_class.item_path?("#{uuid}/issues/42.yml", uuid)).to be(true)
      expect(described_class.item_path?("#{uuid}/issues/42.yaml", uuid)).to be(false)
      expect(described_class.item_path?("#{uuid}/issues/x.yml", uuid)).to be(false)
      expect(described_class.item_path?("#{uuid}/merge_requests/1.yml", uuid)).to be(false)
      expect(described_class.item_path?("other/issues/1.yml", uuid)).to be(false)
    end
  end

  it 'is empty when nothing editable changed' do
    expect(diff(original)).to be_empty
  end

  it 'reports changed fields with their old and new values' do
    edit = diff(original.merge('title' => 'New', 'state' => 'closed', 'confidential' => true,
      'description' => nil, 'due_date' => nil))

    expect(edit.iid).to eq(42)
    expect(edit.fields).to eq(
      'title' => %w[Old New], 'state' => %w[opened closed], 'confidential' => [false, true],
      'description' => ['Text', nil], 'due_date' => [Date.new(2026, 12, 1), nil])
  end

  it 'does not count a date written differently as a change' do
    expect(diff("#{original.except('due_date').to_yaml}due_date: '2026-12-01'\n")).to be_empty
  end

  it 'reads labels and the milestone by title' do
    edit = diff(original.merge(
      'label_links' => original['label_links'] + [{ 'label' => { 'title' => 'ux' } }],
      'milestone' => { 'title' => '2.0' }))

    expect(edit.fields).to eq('label_links' => [%w[bug], %w[bug ux]], 'milestone' => ['1.0', '2.0'])
  end

  it 'removes the milestone and every label' do
    edit = diff(original.except('label_links', 'milestone'))

    expect(edit.fields).to eq('label_links' => [%w[bug], []], 'milestone' => ['1.0', nil])
  end

  describe 'comments' do
    it 'reads a new comment, wherever it is in the list' do
      edit = diff(original.merge('notes' => [{ 'note' => 'Offline' }, comment]))

      expect(edit.new_notes.map(&:note)).to eq(%w[Offline])
      expect(edit.edited_notes).to be_empty
    end

    it 'reads an edited comment by its author, time and discussion' do
      edit = diff(original.merge('notes' => [comment.merge('note' => 'Fixed')]))

      expect(edit.edited_notes.first).to have_attributes(
        author_id: 7, created_at: comment['created_at'], discussion_id: 'abc', old_note: 'First', note: 'Fixed')
    end

    it 'refuses deleting a comment' do
      expect(error_for(original.merge('notes' => []))).to include('comments cannot be deleted offline')
    end

    it 'refuses a new comment with anything but its text' do
      expect(error_for(original.merge('notes' => [comment, { 'note' => 'x', 'system' => true }])))
        .to include('a new comment may only have "note"')
    end

    it 'refuses a new comment without text' do
      expect(error_for(original.merge('notes' => [comment, { 'note' => '' }]))).to include('needs "note" text')
    end

    it 'refuses changing anything but the text' do
      expect(error_for(original.merge('notes' => [comment.merge('note' => 'x', 'system' => true)])))
        .to include('only the text of the comment')
    end

    it 'refuses editing a system note' do
      system_note = comment.merge('system' => true)
      old = original.merge('notes' => [system_note])

      expect { diff(old.merge('notes' => [system_note.merge('note' => 'x')]), old) }
        .to raise_error(described_class::Error, /is a system note/)
    end

    it 'refuses editing one of two comments it cannot tell apart' do
      twin = comment.merge('note' => 'Second')
      old = original.merge('notes' => [comment, twin])

      expect { diff(old.merge('notes' => [comment, twin.merge('note' => 'x')]), old) }
        .to raise_error(described_class::Error, /matches more than one comment/)
    end
  end

  describe '#statuses' do
    let(:edit) do
      diff(original.merge('title' => 'New', 'label_links' => [], 'notes' => [comment.merge('note' => 'Fixed')]))
    end

    def statuses_with(changes)
      edit.statuses(original.merge(changes).to_yaml).transform_keys { |key| key.is_a?(String) ? key : :comment }
    end

    it 'is pending while the item still has the values the push started from' do
      expect(statuses_with({})).to eq('title' => :pending, 'label_links' => :pending, :comment => :pending)
    end

    it 'is done for a value the item already has' do
      expect(statuses_with('title' => 'New')['title']).to eq(:done)
    end

    it 'is a conflict for anything else, ignoring fields the push left alone' do
      statuses = statuses_with('title' => 'Other', 'description' => 'Other',
        'label_links' => [{ 'label' => { 'title' => 'ux' } }], 'notes' => [comment.merge('note' => 'Web')])

      expect(statuses).to eq('title' => :conflict, 'label_links' => :conflict, :comment => :conflict)
    end

    it 'is done for a new comment once its author has posted one with its text' do
      edit = diff(original.merge('notes' => [comment, { 'note' => 'New' }]))
      posted = comment.merge('note' => 'New', 'created_at' => '2026-02-01T00:00:00.000Z')
      new_note = edit.new_notes.first

      expect(edit.statuses(original.to_yaml, author_id: 7)[new_note]).to eq(:pending)
      expect(edit.statuses(original.merge('notes' => [comment, posted]).to_yaml, author_id: 7)[new_note]).to eq(:done)
      expect(edit.statuses(original.merge('notes' => [comment, posted]).to_yaml, author_id: 8)[new_note])
        .to eq(:pending)
    end

    it 'is a conflict for a comment that is gone' do
      expect(statuses_with('notes' => [])[:comment]).to eq(:conflict)
    end
  end

  using RSpec::Parameterized::TableSyntax

  where(:change, :message) do
    { 'author_id' => 8 }                                         | '"author_id" cannot be changed offline'
    { 'web_url' => 'x' }                                         | '"web_url" cannot be changed offline'
    { 'title' => "a\nb" }                                        | '"title" must be one line'
    { 'title' => '' }                                            | '"title" must be one line'
    { 'state' => 'locked' }                                      | '"state" must be one of'
    { 'confidential' => 'yes' }                                  | '"confidential" must be true or false'
    { 'due_date' => 'soon' }                                     | '"due_date" must be a date'
    { 'label_links' => [{ 'label' => { 'title' => 'bug', 'color' => '#000' } }] } | 'can only be added or removed'
    { 'label_links' => [{ 'label' => {} }] }                     | 'needs label: { title'
    { 'milestone' => { 'title' => '1.0', 'state' => 'closed' } } | 'can only be replaced or removed'
    { 'milestone' => 'v2' }                                      | '"milestone" needs a title'
  end

  with_them do
    it 'refuses it, naming the file' do
      message_text = error_for(original.merge(change))

      expect(message_text).to start_with("#{path}:")
      expect(message_text).to include(message)
    end
  end

  it 'refuses a title over the length limit' do
    expect(error_for(original.merge('title' => 'x' * (Issuable::TITLE_LENGTH_MAX + 1)))).to include('longer than')
  end

  it 'refuses YAML that does not parse, with its line' do
    expect(error_for("title: [unclosed\n")).to match(/\A#{Regexp.escape(path)}:\d+:/)
  end

  it 'refuses a duplicated key' do
    expect(error_for("#{original.to_yaml}title: Again\n")).to include('"title" appears twice')
  end

  it 'refuses anchors and aliases' do
    expect(error_for("#{original.except('title', 'description').to_yaml}title: &t x\ndescription: *t\n"))
      .to include('Alias')
  end
end
