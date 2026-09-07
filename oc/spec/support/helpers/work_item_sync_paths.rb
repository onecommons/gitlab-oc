# frozen_string_literal: true

# Path helper for specs that read or write files on the work items sync branch.
#
# Everything the sync writes hangs off this instance's uuid directory, so a spec
# asserting on a branch path has to build it the way the code does.
#
# Including this module also pins the uuid, which is not optional: the test
# environment has no uuid at all. Gitlab::CurrentSettings falls back to
# ApplicationSetting.build_from_defaults there, and `uuid` is set by the
# before_validation ensure_uuid! rather than being a default -- so an unsaved
# settings object has none, and OC::WorkItems.instance_directory raises. Pinning
# it also keeps the paths readable in failure output instead of showing whatever
# random uuid the environment happened to have.
#
# Stubbed on Gitlab::CurrentSettings directly rather than through
# stub_application_setting: that is the form the surrounding specs already use
# for this attribute, and it does not depend on how the settings object is
# memoized.
module WorkItemSyncPaths
  SYNC_INSTANCE_UUID = '9f3c1e77-4b2a-4d18-9a6e-2c5f8b710d43'

  def self.included(base)
    base.before do
      allow(::Gitlab::CurrentSettings).to receive(:uuid).and_return(SYNC_INSTANCE_UUID)
    end
  end

  def sync_path(suffix)
    "#{OC::WorkItems.instance_directory}/#{suffix}"
  end
end
