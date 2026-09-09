import templates from 'oc_else_ce/projects/default_project_templates';

describe('Unfurl project templates', () => {
  it('maps every selectable template to its expected label and icon', () => {
    expect(templates).toEqual({
      application_blueprint: {
        text: 'Application Blueprint',
        icon: '.template-option .icon-application_blueprint',
      },
      unfurl_testbed: {
        text: 'Testbed',
        icon: '.template-option .icon-unfurl_testbed',
      },
      unfurl_dashboard: {
        text: 'Dashboard',
        icon: '.template-option .icon-unfurl_dashboard',
      },
      terraform_blueprint: {
        text: 'Terraform Blueprint',
        icon: '.template-option .icon-terraform_blueprint',
      },
      ansible_blueprint: {
        text: 'Ansible Blueprint',
        icon: '.template-option .icon-ansible_blueprint',
      },
    });
  });
});
