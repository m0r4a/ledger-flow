## 20 July

### S01 1.1

I started with the aws sso thing, it's been tough, everything is new and there's a lot of moving parts.
AWS organizations, AWS IAM Identity Center and AWS IAM.

My curret setup is:

In the AWS organizations:
- mora-management (with, of course, management privileges)
- mora-dev

In AWS IAM Identity Center:
- `Mora` user with access to both accounts, `mora-management` and `mora-dev`

It created a url, something like this:

```
https://d-9e39nena3an.awsapps.com/start
```

## 21 July

### S01 1.1

Then I logged in on the aws cli:

```bash
aws configure sso
```

But I didn't configured it correctly, the correct config looks like this:

```toml
[default]
region = us-east-2
[profile lf-dev]
sso_session = lf-dev
sso_account_id = 297318163711
sso_role_name = AdministratorAccess
region = us-east-2
output = json
[sso-session lf-dev]
sso_start_url = https://d-9e39nena3an.awsapps.com/start
sso_region = us-east-2
sso_registration_scopes = sso:account:access
```

Then I verified the log in:

```
aws sso login --profile lf-dev
aws sts get-caller-identity --profile lf-dev
```

And worked properly
