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

### S01 1.2

```bash
terraform --version
Terraform v1.15.8
```

### S01 1.3

I created the tflint file on the root folder

I had issues with the `tflint --init` command apparently my `GITHUB_TOKEN` env var clashes with the request, I unsetted the variable and I was able to run the init command.

### S01 1.4

I authenticated and added my user to infracost [the dashboard](https://dashboard.infracost.io/org/m0r4a/overview) but there's nothing to check

### S01 1.5

```bash
 > go version
go version go1.26.5-X:nodwarf5 linux/amd64

 > golangci-lint --version
golangci-lint has version 2.12.2 built with go1.26.3-X:nodwarf5 from c0d3ddc9cf3faa61a4e378e879ece580256d76e5 on 2026-05-31T13:58:06Z

 > docker buildx version
github.com/docker/buildx 0.35.0 a319e5b15052cf6557ceb666eb8ff6e32380b782
```
