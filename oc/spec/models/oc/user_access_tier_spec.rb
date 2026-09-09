# frozen_string_literal: true

require 'spec_helper'

RSpec.describe User, feature_category: :user_management do
  it 'classifies only authenticated non-admin, non-external users as advanced' do
    expect(create(:user).advanced).to be(true)
    expect(create(:user, :admin).advanced).to be(false)
    expect(create(:user, :external).advanced).to be(false)
  end

  it 'keeps developer navigation eligibility separate from the advanced tier' do
    expect(create(:user, :admin).developer?).to be(true)
    expect(create(:user, :external).developer?).to be(false)
  end
end
