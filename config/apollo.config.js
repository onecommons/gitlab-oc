module.exports = {
  client: {
    service: {
      name: 'gitlab',
      localSchemaFile: './tmp/tests/graphql/gitlab_schema.graphql',
    },
    // OC Change
    includes: ['../{ee/,jh/,oc/,}app/assets/javascripts/**/*.{js,graphql}'],
    excludes: ['../{ee/,jh/,oc/,}spec/{frontend,frontend_integration}/**/*'],
  },
};
