/*
Create SES domain identity and verify it with Route53 DNS records
*/
data "aws_region" "current" {}

resource "aws_ses_domain_identity" "ses_domain" {
  count = module.this.enabled ? 1 : 0

  domain = var.domain
}

resource "aws_route53_record" "amazonses_verification_record" {
  count = module.this.enabled && var.verify_domain ? 1 : 0

  zone_id = var.zone_id
  name    = "_amazonses.${var.domain}"
  type    = "TXT"
  ttl     = "600"
  records = [join("", aws_ses_domain_identity.ses_domain.*.verification_token)]
}

resource "aws_ses_domain_dkim" "ses_domain_dkim" {
  count = module.this.enabled ? 1 : 0

  domain = join("", aws_ses_domain_identity.ses_domain.*.domain)
}

resource "aws_route53_record" "amazonses_dkim_record" {
  count = module.this.enabled && var.verify_dkim ? 3 : 0

  zone_id = var.zone_id
  name    = "${element(aws_ses_domain_dkim.ses_domain_dkim.0.dkim_tokens, count.index)}._domainkey.${var.domain}"
  type    = "CNAME"
  ttl     = "600"
  records = ["${element(aws_ses_domain_dkim.ses_domain_dkim.0.dkim_tokens, count.index)}.dkim.amazonses.com"]
}


#-----------------------------------------------------------------------------------------------------------------------
# OPTIONALLY CREATE A USER AND GROUP WITH PERMISSIONS TO SEND EMAILS FROM SES domain
#-----------------------------------------------------------------------------------------------------------------------
locals {
  create_group_enabled = module.this.enabled && var.ses_group_enabled
  create_user_enabled  = module.this.enabled && var.ses_user_enabled

  ses_group_name = local.create_group_enabled ? coalesce(var.ses_group_name, module.this.id) : null
}

data "aws_iam_policy_document" "ses_policy" {
  count = (module.this.enabled && var.ses_user_enabled) ? 1 : 0

  statement {
    actions   = var.iam_permissions
    resources = concat(aws_ses_domain_identity.ses_domain.*.arn, var.iam_allowed_resources)
  }
}

resource "aws_iam_group" "ses_users" {
  count = local.create_group_enabled ? 1 : 0

  name = local.ses_group_name
  path = var.ses_group_path
}

resource "aws_iam_group_policy" "ses_group_policy" {
  count = local.create_group_enabled ? 1 : 0

  name  = module.this.id
  group = aws_iam_group.ses_users[0].name

  policy = join("", data.aws_iam_policy_document.ses_policy.*.json)
}

resource "aws_iam_user_group_membership" "ses_user" {
  count = local.create_group_enabled && local.create_user_enabled ? 1 : 0

  user = module.ses_user.user_name

  groups = [
    aws_iam_group.ses_users[0].name
  ]
}

module "ses_user" {
  source  = "cloudposse/iam-system-user/aws"
  version = "0.23.1"
  enabled = local.create_user_enabled

  iam_access_key_max_age = var.iam_access_key_max_age

  context = module.this.context
}


resource "aws_iam_user_policy" "sending_emails" {
  #bridgecrew:skip=BC_AWS_IAM_16:Skipping `Ensure IAM policies are attached only to groups or roles` check because this module intentionally attaches IAM policy directly to a user.
  count = local.create_user_enabled && !local.create_group_enabled ? 1 : 0

  name   = module.this.id
  policy = join("", data.aws_iam_policy_document.ses_policy.*.json)
  user   = module.ses_user.user_name
}

#-----------------------------------------------------------------------------------------------------------------------
# OPTIONALLY CONFIGURE SES MAIL_FROM DOMAIN
#-----------------------------------------------------------------------------------------------------------------------

# SES MAIL_FROM Domain
resource "aws_ses_domain_mail_from" "ses_domain_mail_from" {
  count            = var.mail_from_enabled ? 1 : 0
  domain           = aws_ses_domain_identity.ses_domain[count.index].domain
  mail_from_domain = "${var.mail_from_domain}.${aws_ses_domain_identity.ses_domain[count.index].domain}"
}

# Route53 TXT record for MAIL_FROM SPF
resource "aws_route53_record" "ses_domain_mail_from_spf" {
  count   = var.mail_from_enabled ? 1 : 0
  zone_id = var.zone_id
  name    = "${var.mail_from_domain}.${aws_ses_domain_identity.ses_domain[count.index].domain}"
  type    = "TXT"
  ttl     = "600"
  records = ["v=spf1 include:amazonses.com -all"]
}

# Route53 MX record for MAIL_FROM domain from
resource "aws_route53_record" "ses_domain_mail_from_mx_from" {
  count   = var.mail_from_enabled ? 1 : 0
  zone_id = var.zone_id
  name    = "${var.mail_from_domain}.${aws_ses_domain_identity.ses_domain[count.index].domain}"
  type    = "MX"
  ttl     = "600"
  records = [format("10 feedback-smtp.%s.amazonses.com", data.aws_region.current.name)]

}
