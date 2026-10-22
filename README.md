# RKE2 and Rancher Prime on Azure with Terraform

This project contains Terraform code to deploy a RKE2 cluster on Microsoft Azure. You can choose between a single-node setup or a high-availability, three-node cluster. The first node bootstraps the cluster and installs Rancher Prime, and for an HA setup, the other two nodes join as agents.

## Architecture

This configuration will create the following resources in your Azure subscription:

*   **Resource Group**: A container to hold all related resources.
*   **Virtual Network (VNet)**: An isolated network for the cluster.
*   **Subnet**: A dedicated subnet for the RKE2 nodes.
*   **Network Security Group (NSG)**: Firewall rules to control inbound traffic (SSH, HTTP, HTTPS, Kube-API).
*   **Availability Set**: To ensure high availability across the VMs.
*   **Virtual Machines**:
    *   A 1-node (standalone) or 3-node (high-availability) RKE2 cluster running on SLES 15 SP7 VMs. This cluster hosts the Rancher Prime management server.
    *   A configurable number of downstream SLES VMs (defaults to 1) that will be registered as a separate cluster managed by Rancher.
*   **Public IPs**:
    *   One for each VM in the management cluster for direct SSH access.
    *   One for each downstream node VM for direct SSH access.
    *   A static public IP for the Load Balancer frontend.
*   **Azure Load Balancer**: To distribute traffic to the Rancher UI across the management cluster nodes.
*   **Route 53 A Records**: If enabled, records are created for:
    *   The Rancher UI FQDN (`rancher.mydomain.com`).
    *   Each node in the management cluster (`rancher-node-X.mydomain.com`).
    *   Each downstream node (`downstream-node-X.mydomain.com`).

The first node runs a setup script via `user_data` to:
1.  Register the SLES operating system.
2.  Install RKE2 as a server.
3.  Install `cert-manager` for automated TLS certificate management.
4.  Deploy Rancher Prime via Helm, configured with Let's Encrypt.
5.  Enable and configure the Rancher AI assistant ("Liz") with a Google Gemini provider.
6.  Wait for all components to be fully initialized and healthy.

In a 3-node setup, the other two management nodes run a simpler script to join the RKE2 cluster. The downstream nodes are then registered to the Rancher server.

## Prerequisites

Before you begin, ensure you have the following installed and configured:

*   Terraform (>= 1.3.0)
*   Azure CLI
*   AWS CLI (if using Route53 integration)
*   jq (for SCC de-registration on destroy)
*   An active Azure Subscription.
*   An SSH public key (e.g., in `~/.ssh/id_rsa.pub`).

You will also need the following from the SUSE Customer Center:
*   A SUSE Linux Enterprise Server (SLES) registration code.
*   A Rancher Prime registration code.

## Configuration

1.  **Authenticate with Azure**: Log in using the Azure CLI.
    ```sh
    az login
    ```
    If you plan to use the AWS Route53 integration for DNS, make sure your AWS CLI is also configured with credentials.
    ```sh
    aws configure
    ```

2.  **Create a variables file**: This project uses a `terraform.tfvars` file to manage secrets and environment-specific settings. This file is ignored by Git. Create a file named `terraform.tfvars` in the `terraform/` directory and populate it with the required values.

    ```hcl
    # terraform/terraform.tfvars

    azure_location            = "westus"
    azure_resource_group_name = "rg-my-rancher-cluster"
    azure_vm_size             = "Standard_D4s_v5"
    rke2_node_count           = 1 # Can be 1 for a standalone cluster or 3 for an HA cluster
    downstream_node_count     = 1 # Number of downstream nodes to create
    rancher_hostname          = "rancher.mydomain.com"
    domain_name               = "mydomain.com"
    letsencrypt_email         = "my-email@example.com"
    azure_admin_username      = "azureuser"

    # Optional: Specify component versions for a repeatable deployment.
    # Defaults to "v1.35.9+rke2r1" if omitted. RKE2 v1.36+ switches the default
    # packaged ingress controller from ingress-nginx to Traefik; this project's
    # cert-manager/Rancher bootstrap still assumes ingress-nginx, so only pin a
    # v1.36+ version (or "" for latest) if you've also updated the ingress-nginx
    # readiness wait and the cert-manager ClusterIssuer's HTTP-01 solver.
    # rke2_version           = "v1.35.9+rke2r1"
    # cert_manager_version   = "v1.13.1"
    # rancher_version        = "2.9.1"

    # --- Sensitive Values ---
    # Your SSH public key content
    azure_ssh_public_key   = "ssh-rsa AAAA..."

    # Optional: SUSE Customer Center credentials for automatic de-registration on destroy
    scc_username           = "your-scc-username"
    scc_password           = "your-scc-password"

    # SUSE and Rancher registration codes
    sles_reg_code          = "YOUR_SLES_REG_CODE"
    rancher_prime_reg_code = "YOUR_RANCHER_PRIME_REG_CODE"
    gemini_api_key         = "YOUR_GEMINI_API_KEY"
    gemini_model           = "gemini-3-flash-preview" # Optional: The Gemini model to use

    # Secrets for RKE2 and Rancher
    rke2_token             = "a_secure_random_string_for_rke2"
    rancher_bootstrap_password = "a_very_strong_password_for_rancher"

    # Optional: AWS Route53 for automatic DNS record creation
    aws_create_dns_record  = true
    aws_route53_zone_id    = "YOUR_ROUTE53_ZONE_ID"
    ```

## AWS IAM Permissions

If you enable optional AWS integrations like Route 53 (`aws_create_dns_record = true`) or custom certificates from AWS Secrets Manager (`use_letsencrypt = false`), the IAM user or role that Terraform uses must have the corresponding permissions.

You can create an IAM policy with the following JSON and attach it to your user or role. This policy grants the minimum required permissions for both features. You can remove any statement that you do not need.

**Remember to replace `YOUR_ROUTE53_ZONE_ID` and `YOUR_SECRET_ARN` with your actual resource identifiers.**

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

If you have configured the AWS provider and set `aws_create_dns_record = true`, an `A` record for your `rancher_hostname` will be automatically created in your Route53 hosted zone, pointing to the public IP of the Azure Load Balancer.

Additionally, `A` records for each node (`rancher-node1.mydomain.com`, `rancher-node2.mydomain.com`, etc.) will be created using the `domain_name` variable, pointing to their respective public IP addresses. This allows for direct SSH access using a predictable FQDN.

If you are not using the automated DNS creation, you will need to manually create a DNS `A` record pointing to the load balancer's public IP, which is available in the Terraform output.

After the DNS record has propagated, you can access the Rancher UI in your browser at `https://<your-rancher-hostname>`.

## Automatic De-registration

If you provide `scc_username` and `scc_password` variables, Terraform will automatically de-register the **Rancher Manager instance** from the SUSE Customer Center when you run `terraform destroy`.
If you provide `scc_username` and `scc_password` variables, Terraform will automatically de-register the **Rancher Manager instance and all SLES virtual machines** from the SUSE Customer Center when you run `terraform destroy`.

This action targets the registration associated with the Rancher Prime license, which is identified in SCC by the `rancher_hostname` FQDN (e.g., `rancher.mydomain.com`). This helps keep your subscriptions clean and prevents orphaned application entries in SCC. The process is handled by a `destroy` provisioner and requires `jq` to be installed on the machine running Terraform. If credentials are not provided, this step is skipped.
This helps keep your subscriptions clean and prevents orphaned system and application entries in SCC. The process is handled by a `destroy` provisioner and requires `jq` to be installed on the machine running Terraform. If credentials are not provided, this step is skipped.

*   The **Rancher Manager application** registration is identified in SCC by its FQDN (e.g., `rancher.mydomain.com`).
*   Each **SLES VM** is identified by its machine hostname (e.g., `vm-rke2-node-1`).

**Note**: The `deregister-scc.sh` script must be executable. After creating the script, run the following command from within the `terraform` directory:
```sh
chmod +x deregister-scc.sh
```

## Post-Installation Steps

After the Terraform deployment is complete and you can access the Rancher UI, follow these steps to complete the setup for the Rancher AI Assistant.

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

The deployment script automatically configures Rancher to use Google Gemini. You can verify these settings in the UI.

1.  Navigate to `☰ > Global Settings` and select **rancher-ai**.
2.  Confirm that the **LLM Provider** is set to `google-gemini` and the **Gemini LLM Model** matches the value set for the `gemini_model` variable in your `terraform.tfvars` file. The API key is already configured via a Kubernetes secret in the `cattle-system` namespace and does not need to be entered in the UI.
3.  Click `Install UI Tools` to enable the UI components.

## Cleanup

To destroy all the resources created by this project, run the following command:

```sh
terraform destroy
```