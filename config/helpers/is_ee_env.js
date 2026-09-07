const fs = require('fs');
const path = require('path');
const IS_OC = require('./is_oc_env');

const ROOT_PATH = path.resolve(__dirname, '../..');

// The `FOSS_ONLY` is always `string` or `nil`
// Thus the nil or empty string will result
// in using default value: false
//
// The behavior needs to be synchronised with
// lib/gitlab.rb: Gitlab.ee?
const isFossOnly = JSON.parse(process.env.FOSS_ONLY || 'false');
// OC Change: the oc edition is CE plus oc/, never EE
module.exports =
  fs.existsSync(path.join(ROOT_PATH, 'ee', 'app', 'models', 'license.rb')) &&
  !isFossOnly &&
  !IS_OC;
