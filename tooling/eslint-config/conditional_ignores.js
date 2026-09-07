const IS_EE = require('../../config/helpers/is_ee_env');
const IS_JH = require('../../config/helpers/is_jh_env');
const IS_OC = require('../../config/helpers/is_oc_env'); // OC Change

const conditionalIgnores = [];
if (!IS_EE) {
  conditionalIgnores.push('ee/**/*.*');
}
if (!IS_JH) {
  conditionalIgnores.push('jh/**/*.*');
}
// OC Change
if (!IS_OC) {
  conditionalIgnores.push('oc/**/*.*');
}

module.exports = { conditionalIgnores };
