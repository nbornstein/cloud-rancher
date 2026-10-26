# Cloud Rancher: RKE2 and Rancher Prime on Azure, AWS, or GCP with Terraform

This project contains Terraform code to deploy a RKE2 cluster on Microsoft Azure, Amazon Web Services, or Google Cloud Platform - set `cloud_provider` to choose which. You can choose between a single-node setup or a high-availability, three-node cluster. The first node bootstraps the cluster and installs Rancher Prime, and for an HA setup, the other two nodes join as agents.

## Architecture

This configuration creates the following resources in your chosen cloud account:

*   **Networking**: An isolated virtual network for the cluster, a dedicated subnet for the RKE2 nodes, and firewall rules controlling inbound traffic (SSH, HTTP, HTTPS, Kube-API). On Azure this is a Resource Group, Virtual Network (VNet), Subnet, and Network Security Group (NSG); on AWS it's a VPC, Subnet, Internet Gateway/Route Table, and Security Group; on GCP it's a custom-mode VPC Network, Subnetwork, and firewall rules.
*   **Virtual Machines**:
    *   A 1-node (standalone) or 3-node (high-availability) RKE2 cluster running on SLES 15 SP7 VMs (Azure VMs, AWS EC2 instances, or GCP Compute Engine instances). This cluster hosts the Rancher Prime management server. On Azure, these nodes also share an Availability Set for fault/update domain spreading.
    *   A configurable number of plain SLES VMs (defaults to 1, see [Downstream Nodes](#downstream-nodes) below) intended to become downstream clusters managed by Rancher.
*   **Public IPs**:
    *   One for each VM in the management cluster for direct SSH access.
    *   One for each downstream node VM for direct SSH access.
    *   A static public IP for the Load Balancer frontend.
*   **Load Balancer**: Distributes traffic to the Rancher UI across the management cluster nodes - an Azure Standard Load Balancer, an AWS Network Load Balancer, or a GCP external passthrough Network Load Balancer, depending on `cloud_provider`.
*   **Route 53 A Records**: If enabled, records are created for:
    *   The Rancher UI FQDN (`rancher.YOUR_DOMAIN`).
    *   Each node in the management cluster (`rancher-node-X.YOUR_DOMAIN`).
    *   Each downstream node (`downstream-node-X.YOUR_DOMAIN`).

This is independent of `cloud_provider` - Route53 can point at either cloud's load balancer.

Rancher needs a DNS hostname pointing at the Load Balancer's public IP (for the Let's Encrypt HTTP-01 challenge and for accessing the UI). See [DNS Options](#dns-options) below for the three ways to provide one.

The first node runs a setup script via the cloud's VM boot-script mechanism (`user_data` on Azure/AWS, `metadata_startup_script` on GCP) to:
1.  Register the SLES operating system.
2.  Install RKE2 as a server.
3.  Install `cert-manager` for automated TLS certificate management.
4.  Deploy Rancher Prime via Helm, with TLS from either Let's Encrypt or a custom certificate pulled from AWS Secrets Manager. See [TLS / Certificate Options](#tls--certificate-options) below.
5.  Add the official Rancher Extension repositories, so extensions are installable/browsable from the Extensions page without manually clicking "Add Rancher Repositories" first.
6.  Optionally enable and configure the Rancher AI assistant ("Liz") with one of several LLM providers (Gemini, OpenAI, Bedrock, Ollama, or a generic OpenAI-compatible endpoint), including the dashboard extension that surfaces it in the UI.
7.  Optionally add the [SUSE Application Collection](https://apps.rancher.io) as an app repository.
8.  Wait for all components to be fully initialized and healthy.

In a 3-node setup, the other two management nodes run a simpler script to join this same RKE2 cluster as additional servers. The downstream nodes provisioned alongside it are entirely separate - they are not part of the management cluster or its RKE2 install in any way. See [Downstream Nodes](#downstream-nodes) below for what happens (and doesn't happen) on them.

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
    letsencrypt_email         = "YOUR_EMAIL@YOUR_DOMAIN"
    ssh_public_key            = "ssh-rsa AAAA..." # Your SSH public key content, used regardless of cloud_provider

    # --- cloud_provider = "azure" ---
    azure_location            = "westus"
    azure_resource_group_name = "YOUR_RESOURCE_GROUP_NAME"
    azure_rancher_vm_size     = "Standard_D4s_v5"
    azure_downstream_vm_size  = "Standard_D4s_v5"
    azure_admin_username      = "azureuser"

    # --- cloud_provider = "aws" ---
    # aws_region                   = "us-east-1"
    # aws_vpc_cidr                 = "10.1.0.0/16"
    # aws_rancher_instance_type    = "m5.xlarge"
    # aws_downstream_instance_type = "m5.xlarge"
    # aws_admin_username           = "ec2-user"
    # aws_ami_id                   = "" # Leave "" to auto-discover the latest SLES 15 SP7 BYOS AMI
    # aws_sles_ami_owner_id        = "679593333241" # SUSE's AMI-publishing account; only used by the aws_ami_id auto-discovery lookup

    # --- cloud_provider = "gcp" ---
    # gcp_project                  = "YOUR_GCP_PROJECT_ID"
    # gcp_region                   = "us-central1"
    # gcp_zone                     = "us-central1-a"
    # gcp_subnet_cidr              = "10.2.0.0/24"
    # gcp_rancher_machine_type     = "n2-standard-4"
    # gcp_downstream_machine_type  = "n2-standard-4"
    # gcp_admin_username           = "gcpuser"
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
    scc_username           = "YOUR_SCC_USERNAME"
    scc_password           = "YOUR_SCC_PASSWORD"

    # SUSE and Rancher registration codes
    sles_reg_code          = "YOUR_SLES_REG_CODE"
    rancher_prime_reg_code = "YOUR_RANCHER_PRIME_REG_CODE"

    # Optional: Rancher AI Assistant ("Liz"). Leave ai_llm_provider unset (or "")
    # to skip installing the AI Assistant. Set it to one of: gemini, openai,
    # bedrock, ollama, generic-openai, and only populate that provider's
    # variable(s) below.
    # ai_llm_provider         = "gemini"
    # ai_ui_extension_version = "1.1.0" # Version of the rancher-ai-ui dashboard extension to install
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
    # generic_openai_url      = "https://YOUR_ENDPOINT/v1"
    # generic_openai_api_key  = "YOUR_API_KEY"
    # generic_openai_model    = "YOUR_MODEL_NAME"

    # Optional: SUSE Application Collection. Leave app_collection_username
    # unset (or "") to skip adding it as an app repository. See
    # https://apps.rancher.io for a personal access token, or have an
    # organization admin create a service account under Settings > Service
    # accounts for credentials scoped to automation.
    # app_collection_username = "YOUR_APP_COLLECTION_USERNAME"
    # app_collection_password = "YOUR_APP_COLLECTION_ACCESS_TOKEN_OR_SECRET"

    # Secrets for RKE2 and Rancher
    rke2_token             = "a_secure_random_string_for_rke2"
    rancher_bootstrap_password = "a_very_strong_password_for_rancher"

    # --- DNS: pick ONE of the following three options. See "DNS Options" below. ---

    # Option 1: AWS Route53 (automatic DNS record creation)
    # rancher_hostname          = "rancher.YOUR_DOMAIN"
    # domain_name               = "YOUR_DOMAIN"
    # aws_create_route53_record = true
    # aws_route53_zone_id       = "YOUR_ROUTE53_ZONE_ID"

    # Option 2: sslip.io (zero-config, no domain or DNS provider needed)
    use_sslip_io = true

    # Option 3: Manual DNS (you create the A record yourself)
    # rancher_hostname = "rancher.YOUR_DOMAIN"

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

## Azure Permissions

Azure's RBAC model is much coarser-grained than AWS IAM or GCP IAM - there's no equivalent action-by-action policy to assemble. The identity you `az login` with just needs the built-in **Contributor** role, scoped to either the target subscription (if you want Terraform to create the resource group itself, the default in this project) or an existing resource group (if you pre-create one and set `azure_resource_group_name` to it). No custom role is needed for `cloud_provider = "azure"`.

## AWS IAM Permissions

Several things in this project call AWS APIs, each independently optional and needing its own permissions on the IAM user or role Terraform/the AWS CLI uses:

*   `cloud_provider = "aws"`: creating/destroying the VPC, subnet, security group, EC2 instances, Elastic IPs, and Network Load Balancer.
*   Route 53 (`aws_create_route53_record = true`): creating the DNS record.
*   Custom certificates from AWS Secrets Manager (`use_letsencrypt = false`): reading the cert secret.

Attach only the policy/policies below matching the integrations you're actually using - they're independent of each other and of `cloud_provider`.

### Rancher compute (`cloud_provider = "aws"`)

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
        }
    ]
}
```

`ec2:*` and `elasticloadbalancing:*` don't support resource-level scoping for the create actions above (same reasoning AWS's own `AmazonEC2FullAccess`/`ElasticLoadBalancingFullAccess` managed policies use), so `AllowRke2ComputeManagement` is scoped by action instead - it grants nothing outside EC2/VPC/NLB.

### Route 53 (`aws_create_route53_record = true`)

**Remember to replace `YOUR_ROUTE53_ZONE_ID` with your actual hosted zone ID.**

```json
{
    "Version": "2012-10-17",
    "Statement": [
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
        }
    ]
}
```

### Secrets Manager custom TLS certificate (`use_letsencrypt = false`)

**Remember to replace `YOUR_SECRET_ARN` with your actual secret ARN.**

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AllowSecretsManagerRead",
            "Effect": "Allow",
            "Action": "secretsmanager:GetSecretValue",
            "Resource": "YOUR_SECRET_ARN"
        }
    ]
}
```

## GCP IAM Permissions

`cloud_provider = "gcp"` needs permission to manage a VPC network/subnetwork/firewall rules, Compute Engine instances, and the regional external passthrough Network Load Balancer (instance group, health checks, backend services, forwarding rules, and reserved addresses). Unlike AWS, GCP's IAM model is role-based rather than action-list-based, so grant these predefined roles to the principal running Terraform instead of writing a custom policy:

*   `roles/compute.networkAdmin` - the VPC network, subnetwork, firewall rules, and reserved (internal/external) addresses.
*   `roles/compute.instanceAdmin.v1` - the Compute Engine instances and the unmanaged instance group.
*   `roles/compute.loadBalancerAdmin` - the regional health checks, backend services, and forwarding rules.
*   `roles/iam.serviceAccountUser` - required to attach the project's default Compute Engine service account to new instances, even though this project doesn't specify a custom one.

You'll also need the Compute Engine API (`compute.googleapis.com`) enabled on the target project - see [Prerequisites](#prerequisites).

Grant these on your project with:

```sh
PROJECT_ID="YOUR_GCP_PROJECT_ID"
MEMBER="user:YOUR_EMAIL@YOUR_DOMAIN" # or serviceAccount:...

for ROLE in roles/compute.networkAdmin roles/compute.instanceAdmin.v1 roles/compute.loadBalancerAdmin roles/iam.serviceAccountUser; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="$MEMBER" \
    --role="$ROLE"
done
```

This doesn't cover Route53 or Secrets Manager - those remain AWS integrations regardless of `cloud_provider`, so use the matching AWS IAM policy above if you need them alongside GCP compute.

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

Additionally, `A` records for each node (`rancher-node1.YOUR_DOMAIN`, `rancher-node2.YOUR_DOMAIN`, etc.) will be created using the `domain_name` variable, pointing to their respective public IP addresses. This allows for direct SSH access using a predictable FQDN.

If you set `use_sslip_io = true`, no DNS record is needed at all - the hostname is derived from the Load Balancer's public IP and resolves immediately. Check the `rancher_url` Terraform output for the exact hostname.

If you are using neither Route53 nor `sslip.io`, you will need to manually create a DNS `A` record pointing to the load balancer's public IP, which is available in the `load_balancer_public_ip` Terraform output.

After the DNS record has propagated (not applicable for `sslip.io`), you can access the Rancher UI in your browser at `https://<your-rancher-hostname>` (or the `rancher_url` output).

## Downstream Nodes

The `downstream_node_count` variable (default `1`, set to `0` to skip) provisions that many plain SLES 15 SP7 VMs alongside the management cluster. Their boot script only does two things: register the OS with SCC using `sles_reg_code` and apply the latest `zypper` updates. It does **not** install RKE2, K3s, or any other cluster software, and it does **not** import them into Rancher automatically - "downstream node" describes their intended role, not something this project does for you yet.

To turn one into an actual downstream cluster Rancher manages, use Rancher's cluster registration command:

1.  In the Rancher UI, go to **☰ > Cluster Management > Create** and create a new "Custom" cluster (choosing the Kubernetes distribution and version you want). This generates a node registration command rather than provisioning anything itself.
2.  SSH into the downstream VM using the `downstream_node_public_ips` output and the admin username for your `cloud_provider` (`azureuser` on Azure, `ec2-user` on AWS, `gcpuser` on GCP) - `ssh <admin_username>@<ip>`.
3.  Run the generated registration command on the VM. It installs the chosen Kubernetes distribution and registers the node with Rancher in one step.

If you provide `scc_username`/`scc_password`, downstream nodes are de-registered from SCC on `terraform destroy` the same way management nodes are - see [Automatic De-registration](#automatic-de-registration) below.

## Automatic De-registration

If you provide `scc_username` and `scc_password` variables, Terraform will automatically de-register the **Rancher Manager instance and all SLES virtual machines** from the SUSE Customer Center when you run `terraform destroy`.

This action targets the registration associated with the Rancher Prime license, which is identified in SCC by the `rancher_hostname` FQDN (e.g., `rancher.YOUR_DOMAIN`). This helps keep your subscriptions clean and prevents orphaned system and application entries in SCC. The process is handled by a `destroy` provisioner and requires `jq` to be installed on the machine running Terraform. If credentials are not provided, this step is skipped.

*   The **Rancher Manager application** registration is identified in SCC by its FQDN (e.g., `rancher.YOUR_DOMAIN`).
*   Each **SLES VM** is identified by its machine hostname (e.g., `vm-rancher-node-1`).

**Note**: The `deregister-scc.sh` script must be executable. After creating the script, run the following command from within the `terraform` directory:
```sh
chmod +x deregister-scc.sh
```

## Post-Installation Steps

If you set `ai_llm_provider` in your `terraform.tfvars`, the deployment script installs the `rancher-ai-agent` backend (via Helm), the `rancher-ai-ui` Dashboard extension (via a `UIPlugin` resource, pinned to `ai_ui_extension_version`), and that extension's "UI Tools" definition (via a `ConfigMap`, also pinned to `ai_ui_extension_version`) automatically - no manual steps in the Extensions page or the AI Assistant Configuration screen's `Install UI Tools` button are needed. If you left `ai_llm_provider` unset, none of this was installed and these steps don't apply.

### Verify AI Settings

1.  Log into your Rancher UI with the bootstrap password and reload the page if the **SUSE AI Assistant** icon isn't visible yet.
2.  Navigate to `☰ > Global Settings` and select **rancher-ai**.
3.  Confirm that the **LLM Provider** matches your `ai_llm_provider` value, the model field matches the corresponding `*_model` variable, and the API key/URL field for that provider is populated. These are passed directly to the `rancher-ai-agent` Helm chart at install time and don't need to be entered in the UI.
4.  Open the AI Assistant chat and confirm there's no "Install UI Tools"/"Refresh UI Tools" banner - its absence means the `ConfigMap` the script created matches what the installed extension version expects.

Note that because the extension is installed directly as a `UIPlugin` rather than through the Extensions catalog's Helm-backed install flow, it won't appear in the `☰ > Extensions` page's **Installed** tab - that's cosmetic only and doesn't affect functionality. If you ever need to update the extension version, bump `ai_ui_extension_version` and re-run `terraform apply`, then delete the existing `UIPlugin`/re-run the first node's boot script (or apply the updated manifest manually) so the new version takes effect, since it's only created once on first boot.

### Verify the SUSE Application Collection Repository

If you set `app_collection_username` in your `terraform.tfvars`, the deployment script registers `dp.apps.rancher.io` as a `ClusterRepo` named `application-collection`, authenticated with a `kubernetes.io/basic-auth` secret of the same name in the `cattle-system` namespace - no manual steps on the Repositories page are needed.

1.  Log into your Rancher UI and navigate to `☰ > Apps > Repositories`. Confirm `application-collection` is listed with a state of **Active**.
2.  Navigate to `☰ > Apps > Charts` and confirm charts from the Application Collection appear.
3.  When installing an app from this repository, some charts also need an image pull secret to pull their container images (separate from the chart-pull credentials above). If so, create a `kubernetes.io/dockerconfigjson` secret for `dp.apps.rancher.io` in the target app's namespace using your same `app_collection_username`/`app_collection_password`, and reference it via that chart's `global.imagePullSecrets` value.

## Cleanup

To destroy all the resources created by this project, run the following command:

```sh
terraform destroy
```
