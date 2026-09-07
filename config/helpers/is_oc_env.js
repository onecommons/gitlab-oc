const fs = require('fs');
const path = require('path');

const ROOT_PATH = path.resolve(__dirname, '../..');

// The `GITLAB_ONLY` is always `string` or `nil`
// Thus the nil or empty string will result
// in using default value: false
//
// The behavior needs to be synchronised with
// lib/gitlab_edition.rb: GitlabEdition.oc?
const isGitlabOnly = JSON.parse(process.env.GITLAB_ONLY || 'false');
module.exports = fs.existsSync(path.join(ROOT_PATH, 'oc')) && !isGitlabOnly;
