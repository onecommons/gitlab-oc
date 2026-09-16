---
title: Getting Started with Unfurl Cloud
---

**Table of Contents**

 [[_TOC_]]

### Deploy your first application with Unfurl Cloud

Unfurl Cloud allows you to deploy quickly and easily into your own cloud accounts, and integrates with all the tools you already use. Keep track of all your configurations, deployments, history, and changes, all in one place.

In this step-by-step tutorial, you will deploy Apostrophe CMS onto Google Cloud Platform.

**Prerequisites:** Google Cloud Platform account.

**Optional:** MongoDB Atlas account, preferred DNS server

### 1. Select the Application Blueprint for Apostrophe CMS

Our Starter Application Blueprints contain everything you need to deploy an application into your own cloud account, including its requirements, inputs, and outputs. You’ll be able to enter your cloud provider credentials and use these ready-to-deploy blueprints in just a few minutes.

1. Click on “Blueprints” button in the Top Navigation Bar
![Blueprints button](img/select_blueprints_btn.png "Blueprints button")

2. Scroll through and click on "Apostrophe CMS"
![Select an Application Blueprint](img/select_app_blueprint.png "Application Blueprints")

### 2. Select a Deployment Blueprint

**Deployment Blueprints** allow you to quickly connect to external resources or create managed resources. In the "Available Blueprints" section, find "Google Cloud Platform" and click "Deploy". 

### 3. Set up an Environment with your Cloud Provider

The first time you deploy with us, you’ll have to set up an **Environment**. To do so, follow the prompts to: 

1. Name your environment
2. Select GCP as the cloud provider
3. Select a zone or region
4. Set any environment variables 

When you're ready, click “Save” to continue to the deployment process.

**Note**: You will need to sign in to your cloud account to ensure the authentication process worked properly. In this example, you need to setup a project in GCP first and enable billing in your GCP account.

### 4. Connect to external resources and create managed resources

On this screen, you will be prompted to fill in the necessary details to connect to **external resources** and to create **managed resources**. For Apostrophe CMS, this includes the following resources:

- Inputs (required)
- Compute (required)
- MongoDB (optional)
- DNS (optional)
- Mailer (optional)

Once you’ve filled in all your inputs and see all green check marks next to your resources, you’re good to go!

### 5. Click "Deploy"

Once you’ve deployed, you will see the log (after a few minutes), and you can check on your deployment in your dashboard.

 ---
