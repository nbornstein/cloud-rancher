# Cloud Rancher: RKE2 and Rancher Prime on Azure, AWS, or GCP with Terraform

This project contains Terraform code to deploy a RKE2 cluster on Microsoft Azure, Amazon Web Services, or Google Cloud Platform - set `cloud_provider` to choose which. You can choose between a single-node setup or a high-availability, three-node cluster. The first node bootstraps the cluster and installs Rancher Prime, and for an HA setup, the other two nodes join as agents.

## Architecture

This configuration creates the following resources in your chosen cloud account:

*   **Networking**: An isolated virtual network for the cluster, a dedicated subnet for the RKE2 nodes, and firewall rules controlling inbound traffic (SSH, HTTP, HTTPS, Kube-API). On Azure this is a Resource Group, Virtual Network (VNet), Subnet, and Network Security Group (NSG); on AWS it's a VPC, Subnet, Internet Gateway/Route Table, and Security Group; on GCP it's a custom-mode VPC Network, Subnetwork, and firewall rules.
*   **Virtual Machines**:
    *   A 1-node (standalone) or 3-node (high-availability) RKE2 cluster running on SLES 15 SP7 VMs (Azure VMs, AWS EC2 instances, or GCP Compute Engine instances). This cluster hosts the Rancher Prime management server. On Azure, these nodes also share an Availability Set for fault/update domain spreading.
    *   A configurable number of downstream SLES VMs (defaults to 1) that will be registered as a separate cluster managed by Rancher.
*   **Public IPs**:
    *   One for each VM in the management cluster for direct SSH access.
    *   One for each downstream node VM for direct SSH access.
    *   A static public IP for the Load Balancer frontend.
*   **Load Balancer**: Distributes traffic to the Rancher UI across the management cluster nodes - an Azure Standard Load Balancer, an AWS Network Load Balancer, or a GCP external passthrough Network Load Balancer, depending on `cloud_provider`.
*   **Route 53 A Records**: If enabled, records are created for:
    *   The Rancher UI FQDN (`rancher.mydomain.com`).
    *   Each node in the management cluster (`rancher-node-X.mydomain.com`).
    *   Each downstream node (`downstream-node-X.mydomain.com`).

This is independent of `cloud_provider` - Route53 can point at either cloud's load balancer.

Rancher needs a DNS hostname pointing at the Load Balancer's public IP (for the Let's Encrypt HTTP-01 challenge and for accessing the UI). See [DNS Options](#dns-options) below for the three ways to provide one.

The first node runs a setup script via `user_data` to:
1.  Register the SLES operating system.
2.  Install RKE2 as a server.
3.  Install `cert-manager` for automated TLS certificate management.
4.  Deploy Rancher Prime via Helm, with TLS from either Let's Encrypt or a custom certificate pulled from AWS Secrets Manager. See [TLS / Certificate Options](#tls--certificate-options) below.
5.  Optionally enable and configure the Rancher AI assistant ("Liz") with one of several LLM providers (Gemini, OpenAI, Bedrock, Ollama, or a generic OpenAI-compatible endpoint).
6.  Wait for all components to be fully initialized and healthy.

In a 3-node setup, the other two management nodes run a simpler script to join the RKE2 cluster. The downstream nodes are then registered to the Rancher server.

## Prerequisites

Before you begin, ensure you have the following installed and configured:

*   Terraform (>= 1.3.0)
*   Azure CLI (if `cloud_provider = "azure"`), with an active Azure Subscription.
*   AWS CLI, configured with credentials (if `cloud_provider = "aws"`, or if using the Route53 or Secrets Manager custom TLS cert integrations - these are available regardless of `cloud_provider`).
*   `gcloud` CLI (if `cloud_provider = "gcp"`), authenticated via `gcloud auth application-default login`, with the Compute Engine API enabled on the target project.
*   jq (for SCC de-registration on destroy)
*   An SSH public key (e.g., in `~/.ssh/id_rsa.pub`).

You will also need the following from the SUSE Customer Center:
*   A SUSE Linux Enterprise Server (SLES) registration code.
*   A Rancher Prime registration code.

## Configuration

1.  **Authenticate with your chosen cloud**:
    *   For `cloud_provider = "azure"`, log in using the Azure CLI:
        ```sh
        az login
        ```
    *   For `cloud_provider = "aws"`, make sure your AWS CLI is configured with credentials:
        ```sh
        aws configure
        ```
    *   For `cloud_provider = "gcp"`, authenticate with Application Default Credentials:
        ```sh
        gcloud auth application-default login
        ```

    Either way, if you also plan to use the AWS Route53 integration for DNS or the Secrets Manager custom TLS cert option, make sure your AWS CLI is configured with credentials too (`aws configure`) - these work the same regardless of `cloud_provider`. Route53 isn't needed if you use the `sslip.io` or manual DNS options - see [DNS Options](#dns-options).

2.  **Create a variables file**: This project uses a `terraform.tfvars` file to manage secrets and environment-specific settings. This file is ignored by Git. Create a file named `terraform.tfvars` in the `terraform/` directory and populate it with the required values.

    ```hcl
    # terraform/terraform.tfvars

    cloud_provider            = "azure" # or "aws" or "gcp"
    rancher_node_count        = 1 # Can be 1 for a standalone cluster or 3 for an HA cluster
    downstream_node_count     = 1 # Number of downstream nodes to create
    letsencrypt_email         = "my-email@example.com"

    # --- cloud_provider = "azure" ---
    azure_location            = "westus"
    azure_resource_group_name = "rg-my-rancher-cluster"
    azure_rancher_vm_size     = "Standard_D4s_v5"
    azure_downstream_vm_size  = "Standard_D4s_v5"
    azure_admin_username      = "azureuser"
    azure_ssh_public_key      = "ssh-rsa AAAA..." # Your SSH public key content

    # --- cloud_provider = "aws" ---
    # aws_region                   = "us-east-1"
    # aws_rancher_instance_type    = "m5.xlarge"
    # aws_downstream_instance_type = "m5.xlarge"
    # aws_admin_username           = "ec2-user"
    # aws_ssh_public_key           = "ssh-rsa AAAA..." # Your SSH public key content
    # aws_ami_id                   = "" # Leave "" to auto-discover the latest SLES 15 SP7 BYOS AMI
    # aws_sles_ami_owner_id        = "679593333241" # SUSE's AMI-publishing account; only used by the aws_ami_id auto-discovery lookup

    # --- cloud_provider = "gcp" ---
    # gcp_project                  = "my-gcp-project-id"
    # gcp_region                   = "us-central1"
    # gcp_zone                     = "us-central1-a"
    # gcp_subnet_cidr              = "10.2.0.0/24"
    # gcp_rancher_machine_type     = "n2-standard-4"
    # gcp_downstream_machine_type  = "n2-standard-4"
    # gcp_admin_username           = "gcpuser"
    # gcp_ssh_public_key           = "ssh-rsa AAAA..." # Your SSH public key content
    # gcp_image_id                 = "" # Leave "" to auto-discover the latest SLES 15 SP7 BYOS image
    # gcp_sles_image_family        = "sles-15-byos"
    # gcp_sles_image_project       = "suse-byos-cloud"

    # Optional: Specify component versions for a repeatable deployment.
    # Defaults to "v1.35.9+rke2r1" (ingress-nginx) if omitted. Set this to a
    # v1.36+ release, or "" for the latest release, to use Traefik instead -
    # the ingress controller, cert-manager ClusterIssuer, and Rancher Helm
    # chart are all configured automatically to match whichever one applies.
    # rke2_version           = "v1.35.9+rke2r1"
    # cert_manager_version   = "v1.13.1"
    # rancher_version        = "2.9.1"

    # --- Sensitive Values ---

    # Optional: SUSE Customer Center credentials for automatic de-registration on destroy
    scc_username           = "your-scc-username"
    scc_password           = "your-scc-password"

    # SUSE and Rancher registration codes
    sles_reg_code          = "YOUR_SLES_REG_CODE"
    rancher_prime_reg_code = "YOUR_RANCHER_PRIME_REG_CODE"

    # Optional: Rancher AI Assistant ("Liz"). Leave ai_llm_provider unset (or "")
    # to skip installing the AI Assistant. Set it to one of: gemini, openai,
    # bedrock, ollama, generic-openai, and only populate that provider's
    # variable(s) below.
    # ai_llm_provider         = "gemini"
    # gemini_api_key          = "YOUR_GEMINI_API_KEY"
    # gemini_model            = "gemini-3-flash-preview"
    # openai_api_key          = "YOUR_OPENAI_API_KEY"
    # openai_model            = "gpt-4o"
    # bedrock_bearer_token    = "YOUR_BEDROCK_BEARER_TOKEN"
    # bedrock_model           = "global.anthropic.claude-opus-4-5-20251101-v1:0"
    # bedrock_region          = "us-east-1"
    # bedrock_url             = "" # Optional: custom Bedrock VPC endpoint
    # ollama_url              = "http://ollama:11434"
    # ollama_model            = "gpt-oss:120b"
    # generic_openai_url      = "https://myendpoint.example/v1"
    # generic_openai_api_key  = "YOUR_API_KEY"
    # generic_openai_model    = "your-model-name"

    # Secrets for RKE2 and Rancher
    rke2_token             = "a_secure_random_string_for_rke2"
    rancher_bootstrap_password = "a_very_strong_password_for_rancher"

    # --- DNS: pick ONE of the following three options. See "DNS Options" below. ---

    # Option 1: AWS Route53 (automatic DNS record creation)
    # rancher_hostname          = "rancher.mydomain.com"
    # domain_name               = "mydomain.com"
    # aws_create_route53_record = true
    # aws_route53_zone_id       = "YOUR_ROUTE53_ZONE_ID"

    # Option 2: sslip.io (zero-config, no domain or DNS provider needed)
    use_sslip_io = true

    # Option 3: Manual DNS (you create the A record yourself)
    # rancher_hostname = "rancher.mydomain.com"

    # --- TLS: pick ONE of the following two options. See "TLS / Certificate Options" below. ---

    # Option 1: Let's Encrypt (default - no extra variables needed beyond letsencrypt_email above)
    # use_letsencrypt = true

    # Option 2: Custom certificate from AWS Secrets Manager
    # use_letsencrypt         = false
    # aws_tls_cert_secret_arn = "YOUR_SECRET_ARN"
    ```

## DNS Options

Rancher needs a hostname that resolves to the cloud load balancer's public IP, both so you can reach the UI and so cert-manager can complete the Let's Encrypt HTTP-01 challenge. Pick one:

1.  **AWS Route53** (`aws_create_route53_record = true`): Terraform creates the `A` record for you in a Route53 hosted zone you own. Requires an AWS account, a domain delegated to Route53, and the IAM permissions below.
2.  **sslip.io** (`use_sslip_io = true`): No domain, DNS provider, or AWS account needed. The hostname is derived automatically from the Load Balancer's public IP (e.g. `20-1-2-3.sslip.io`) and is available for Terraform output as `rancher_url`. `sslip.io`'s nameservers answer with the embedded IP, so there's no record to create or propagate - it resolves immediately. Leave `rancher_hostname`, `domain_name`, and the `aws_route53_*`/`aws_create_route53_record` variables unset.
3.  **Manual**: Set `rancher_hostname` to a hostname you manage elsewhere (any DNS provider, or your own domain registrar), and point its `A` record at the Load Balancer's public IP (the `load_balancer_public_ip` Terraform output) yourself, either before or after `terraform apply`.

## TLS / Certificate Options

Rancher's ingress needs a TLS certificate for the hostname you chose above. Pick one:

1.  **Let's Encrypt** (`use_letsencrypt = true`, the default): `cert-manager` requests a certificate automatically via the HTTP-01 challenge against `rancher_hostname`, using `letsencrypt_email` as the account contact. No AWS account is needed for this option alone.
2.  **Custom certificate from AWS Secrets Manager** (`use_letsencrypt = false`): Terraform reads `aws_tls_cert_secret_arn`, a Secrets Manager secret whose value is a JSON object with `tls.crt` and `tls.key` keys (PEM-encoded), and creates the `cattle-system/tls-rancher-ingress` secret from them. If the JSON also includes a CA certificate under `cacerts.pm` (or `cacerts.pem`/`ca.crt`), it's installed as the `cattle-system/tls-ca` secret so Rancher trusts that CA for downstream agents. Requires an AWS account and the IAM permissions below.

## AWS IAM Permissions

Several things in this project call AWS APIs, each needing its own permissions on the IAM user or role Terraform/the AWS CLI uses:

*   `cloud_provider = "aws"`: creating/destroying the VPC, subnet, security group, EC2 instances, Elastic IPs, and Network Load Balancer.
*   Route 53 (`aws_create_route53_record = true`): creating the DNS record.
*   Custom certificates from AWS Secrets Manager (`use_letsencrypt = false`): reading the cert secret.

You can create an IAM policy with the following JSON and attach it to your user or role. This policy grants the minimum required permissions for all three. Remove whichever statement(s) you don't need - e.g. drop `AllowRke2ComputeManagement` entirely if `cloud_provider = "azure"` or `"gcp"`, and drop the whole policy if neither Route53 nor Secrets Manager is in use either.

**Remember to replace `YOUR_ROUTE53_ZONE_ID` and `YOUR_SECRET_ARN` with your actual resource identifiers.**

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AllowRke2ComputeManagement",
            "Effect": "Allow",
            "Action": [
                "ec2:DescribeAccountAttributes",
                "ec2:DescribeAvailabilityZones",
                "ec2:DescribeImages",
                "ec2:DescribeVpcs",
                "ec2:DescribeVpcAttribute",
                "ec2:DescribeSubnets",
                "ec2:DescribeSecurityGroups",
                "ec2:DescribeRouteTables",
                "ec2:DescribeInternetGateways",
                "ec2:DescribeInstances",
                "ec2:DescribeInstanceAttribute",
                "ec2:DescribeInstanceTypes",
                "ec2:DescribeNetworkInterfaces",
                "ec2:DescribeNetworkInterfaceAttribute",
                "ec2:CreateNetworkInterface",
                "ec2:DeleteNetworkInterface",
                "ec2:ModifyNetworkInterfaceAttribute",
                "ec2:AttachNetworkInterface",
                "ec2:DetachNetworkInterface",
                "ec2:DescribeAddresses",
                "ec2:DescribeAddressesAttribute",
                "ec2:DescribeKeyPairs",
                "ec2:DescribeTags",
                "ec2:DescribeVolumes",
                "ec2:CreateVpc",
                "ec2:ModifyVpcAttribute",
                "ec2:DeleteVpc",
                "ec2:CreateSubnet",
                "ec2:ModifySubnetAttribute",
                "ec2:DeleteSubnet",
                "ec2:CreateInternetGateway",
                "ec2:AttachInternetGateway",
                "ec2:DetachInternetGateway",
                "ec2:DeleteInternetGateway",
                "ec2:CreateRouteTable",
                "ec2:CreateRoute",
                "ec2:DeleteRoute",
                "ec2:AssociateRouteTable",
                "ec2:DisassociateRouteTable",
                "ec2:DeleteRouteTable",
                "ec2:CreateSecurityGroup",
                "ec2:AuthorizeSecurityGroupIngress",
                "ec2:AuthorizeSecurityGroupEgress",
                "ec2:RevokeSecurityGroupIngress",
                "ec2:RevokeSecurityGroupEgress",
                "ec2:DeleteSecurityGroup",
                "ec2:ImportKeyPair",
                "ec2:DeleteKeyPair",
                "ec2:RunInstances",
                "ec2:TerminateInstances",
                "ec2:ModifyInstanceAttribute",
                "ec2:AllocateAddress",
                "ec2:AssociateAddress",
                "ec2:DisassociateAddress",
                "ec2:ReleaseAddress",
                "ec2:CreateTags",
                "ec2:DeleteTags",
                "elasticloadbalancing:DescribeLoadBalancers",
                "elasticloadbalancing:DescribeLoadBalancerAttributes",
                "elasticloadbalancing:CreateLoadBalancer",
                "elasticloadbalancing:ModifyLoadBalancerAttributes",
                "elasticloadbalancing:DeleteLoadBalancer",
                "elasticloadbalancing:DescribeTargetGroups",
                "elasticloadbalancing:DescribeTargetGroupAttributes",
                "elasticloadbalancing:CreateTargetGroup",
                "elasticloadbalancing:ModifyTargetGroupAttributes",
                "elasticloadbalancing:DeleteTargetGroup",
                "elasticloadbalancing:DescribeListeners",
                "elasticloadbalancing:DescribeListenerAttributes",
                "elasticloadbalancing:CreateListener",
                "elasticloadbalancing:DeleteListener",
                "elasticloadbalancing:RegisterTargets",
                "elasticloadbalancing:DeregisterTargets",
                "elasticloadbalancing:DescribeTargetHealth",
                "elasticloadbalancing:AddTags",
                "elasticloadbalancing:DescribeTags"
            ],
            "Resource": "*"
        },
        {
            "Sid": "AllowElbServiceLinkedRoleCreation",
            "Effect": "Allow",
            "Action": "iam:CreateServiceLinkedRole",
            "Resource": "arn:aws:iam::*:role/aws-service-role/elasticloadbalancing.amazonaws.com/AWSServiceRoleForElasticLoadBalancing*",
            "Condition": {
                "StringEquals": {
                    "iam:AWSServiceName": "elasticloadbalancing.amazonaws.com"
                }
            }
        },
        {
            "Sid": "AllowRoute53Management",
            "Effect": "Allow",
            "Action": [
                "route53:GetHostedZone",
                "route53:ListResourceRecordSets",
                "route53:ChangeResourceRecordSets"
            ],
            "Resource": "arn:aws:route53:::hostedzone/YOUR_ROUTE53_ZONE_ID"
        },
        {
            "Sid": "AllowRoute53GetChange",
            "Effect": "Allow",
            "Action": "route53:GetChange",
            "Resource": "arn:aws:route53:::change/*"
        },
        {
            "Sid": "AllowSecretsManagerRead",
            "Effect": "Allow",
            "Action": "secretsmanager:GetSecretValue",
            "Resource": "YOUR_SECRET_ARN"
        }
    ]
}
```

`ec2:*` and `elasticloadbalancing:*` don't support resource-level scoping for the create actions above (same reasoning AWS's own `AmazonEC2FullAccess`/`ElasticLoadBalancingFullAccess` managed policies use), so `AllowRke2ComputeManagement` is scoped by action instead - it grants nothing outside EC2/VPC/NLB.

## Deployment

1.  **Initialize Terraform**: Navigate to the `terraform` directory and initialize the providers.
    ```sh
    cd terraform
    terraform init
    ```

2.  **Plan the deployment**: Review the resources that Terraform will create.
    ```sh
    terraform plan
    ```

3.  **Apply the configuration**: Deploy the infrastructure. This process will take several minutes as it involves provisioning VMs and bootstrapping Rancher.
    ```sh
    terraform apply
    ```
    The script will pause for up to 20 minutes while it waits for the Rancher server to be fully installed and become healthy. Terraform polls the health endpoint of the Rancher instance and will only complete the `apply` process once it receives a successful response. This ensures that when the command finishes, your Rancher UI is ready to be accessed.

## Accessing Rancher

Once the deployment is complete, you can access the Rancher UI.

If you have configured the AWS provider and set `aws_create_route53_record = true`, an `A` record for your `rancher_hostname` will be automatically created in your Route53 hosted zone, pointing to the public IP of the cloud load balancer (Azure, AWS, or GCP, depending on `cloud_provider`).

Additionally, `A` records for each node (`rancher-node1.mydomain.com`, `rancher-node2.mydomain.com`, etc.) will be created using the `domain_name` variable, pointing to their respective public IP addresses. This allows for direct SSH access using a predictable FQDN.

If you set `use_sslip_io = true`, no DNS record is needed at all - the hostname is derived from the Load Balancer's public IP and resolves immediately. Check the `rancher_url` Terraform output for the exact hostname.

If you are using neither Route53 nor `sslip.io`, you will need to manually create a DNS `A` record pointing to the load balancer's public IP, which is available in the `load_balancer_public_ip` Terraform output.

After the DNS record has propagated (not applicable for `sslip.io`), you can access the Rancher UI in your browser at `https://<your-rancher-hostname>` (or the `rancher_url` output).

## Automatic De-registration

If you provide `scc_username` and `scc_password` variables, Terraform will automatically de-register the **Rancher Manager instance and all SLES virtual machines** from the SUSE Customer Center when you run `terraform destroy`.

This action targets the registration associated with the Rancher Prime license, which is identified in SCC by the `rancher_hostname` FQDN (e.g., `rancher.mydomain.com`). This helps keep your subscriptions clean and prevents orphaned system and application entries in SCC. The process is handled by a `destroy` provisioner and requires `jq` to be installed on the machine running Terraform. If credentials are not provided, this step is skipped.

*   The **Rancher Manager application** registration is identified in SCC by its FQDN (e.g., `rancher.mydomain.com`).
*   Each **SLES VM** is identified by its machine hostname (e.g., `vm-rancher-node-1`).

**Note**: The `deregister-scc.sh` script must be executable. After creating the script, run the following command from within the `terraform` directory:
```sh
chmod +x deregister-scc.sh
```

## Post-Installation Steps

If you set `ai_llm_provider` in your `terraform.tfvars`, follow these steps after the Terraform deployment is complete to finish setting up the Rancher AI Assistant. If you left `ai_llm_provider` unset, the AI Assistant was not installed and these steps don't apply.

### 1. Add Extension Repositories

The Rancher UI is extended through a marketplace of extensions. You must first add the repositories that host these extensions.

1.  Log into your Rancher UI with the bootstrap password.
2.  Navigate to `☰ > Extensions`.
3.  Click **Add Rancher Repositories**.
4.  Navigate away from the `☰ > Extensions` page in order to force a refresh.

### 2. Install the AI Assistant Extension

Once the repository is added, the AI Assistant extension will become available for installation.

1.  Return to the `☰ > Extensions` page.
2.  Under the **Available** tab, find the **AI Assistant** extension and click **Install**.
3.  Once the extension has finished installing, click the `Reload` button that appears at the top of the page.

### 3. Verify AI Settings

The deployment script automatically configures Rancher to use the LLM provider set in `ai_llm_provider`. You can verify these settings in the UI.

1.  Navigate to `☰ > Global Settings` and select **rancher-ai**.
2.  Confirm that the **LLM Provider** matches your `ai_llm_provider` value, the model field matches the corresponding `*_model` variable, and the API key/URL field for that provider is populated. These are passed directly to the `rancher-ai-agent` Helm chart at install time and don't need to be entered in the UI.
3.  Click `Install UI Tools` to enable the UI components.

## Cleanup

To destroy all the resources created by this project, run the following command:

```sh
terraform destroy
```