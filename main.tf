variable "api_key" {
  description = "The API key for my service"
  type        = string
  sensitive   = true
}

variable "tenancy_ocid" {
  type        = string
  description = "The tenancy OCID"
  default     = "ocid1.tenancy.oc1..aaaaaaaa6yl7bv6bhi4x5b3qzzy6ytaky4kcpkxi2aoksn5h3jeclie37g5q"
}

variable "user_ocid" {
  type        = string
  description = "The user OCID"
  default     = "ocid1.user.oc1..aaaaaaaa3ok66cdd4w32jstkxy3o4rw5yvictnzhpl7tv4q4rrgpe44wwdbq"
}


variable "vm_shape" {
  type        = string
  description = "The shape of the VM"
  default     = "VM.Standard.E2.2"
}

provider "oci" {
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.api_key
  private_key_path = "/home/opc/r0937863student.thomasmore.be_2023-12-01T09_39_33.529Z.pem"
  region           = "eu-amsterdam-1"
}

data "oci_identity_availability_domains" "availability_domains" {
  compartment_id = var.tenancy_ocid
}

resource "oci_core_vcn" "vcn" {
  #Required
  compartment_id = var.tenancy_ocid
  cidr_block     = "10.0.0.0/16"
}


# allow port 80
resource "oci_core_security_list" "ScarlettVM" {
  #Required
  compartment_id = var.tenancy_ocid
  vcn_id         = oci_core_vcn.vcn.id
  display_name   = "ScarlettVM"
  ingress_security_rules {
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    protocol    = "6" # TCP
    tcp_options {
      max = 80
      min = 80
    }
  }

  ingress_security_rules {
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    protocol    = "6" # TCP
    tcp_options {
      max = 22
      min = 22
    }
  }
  egress_security_rules {
    destination  = "0.0.0.0/0"
    protocol    = "all"
  }
}

# allow port 80
resource "oci_core_security_list" "ZabbixVM" {
  #Required
  compartment_id = var.tenancy_ocid
  vcn_id         = oci_core_vcn.vcn.id
  display_name   = "ZabbixVM"
  ingress_security_rules {
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    protocol    = "6" # TCP
    tcp_options {
      max = 80
      min = 80
    }
  }

  ingress_security_rules {
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    protocol    = "6" # TCP
    tcp_options {
      max = 22
      min = 22
    }
  }
  egress_security_rules {
    destination  = "0.0.0.0/0"
    protocol    = "all"
  }
}



resource "oci_core_internet_gateway" "internet_gateway" {
  compartment_id = var.tenancy_ocid
  vcn_id         = oci_core_vcn.vcn.id
}

resource "oci_core_route_table" "internet" {
  compartment_id = var.tenancy_ocid
  vcn_id         = oci_core_vcn.vcn.id

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.internet_gateway.id
  }
}


resource "oci_core_subnet" "subnet" {
  #Required
  compartment_id      = var.tenancy_ocid
  availability_domain = data.oci_identity_availability_domains.availability_domains.availability_domains.0.name
  cidr_block          = "10.0.1.0/24"
  vcn_id              = oci_core_vcn.vcn.id
  route_table_id      = oci_core_route_table.internet.id
  security_list_ids = [
    oci_core_security_list.ScarlettVM.id,
    oci_core_security_list.ZabbixVM.id
  ]
}

data "oci_core_images" "centos" {
  compartment_id           = var.tenancy_ocid
  operating_system         = "CentOS"
  operating_system_version = "8 Stream"
  shape                    = var.vm_shape
}

resource "oci_core_instance" "ScarlettVM" {
  availability_domain = data.oci_identity_availability_domains.availability_domains.availability_domains.0.name
  compartment_id      = var.tenancy_ocid
  display_name        = "ScarlettVM"
  shape               = var.vm_shape

  source_details {
    source_type = "image"
    source_id   = data.oci_core_images.centos.images.0.id
  }

  create_vnic_details {
    assign_public_ip = true
    subnet_id        = oci_core_subnet.subnet.id
  }

  # Add SSH key
  extended_metadata = {
    ssh_authorized_keys = file("~/.ssh/id_rsa.pub")
  }
}

resource "oci_core_instance" "ZabbixVM" {
  availability_domain = data.oci_identity_availability_domains.availability_domains.availability_domains.0.name
  compartment_id      = var.tenancy_ocid
  display_name        = "ZabbixVM"
  shape               = var.vm_shape

  source_details {
    source_type = "image"
    source_id   = data.oci_core_images.centos.images.0.id
  }

  create_vnic_details {
    assign_public_ip = true
    subnet_id        = oci_core_subnet.subnet.id
  }

  # Add SSH key
  extended_metadata = {
    ssh_authorized_keys = file("~/.ssh/id_rsa.pub")
  }
}

resource "time_sleep" "wait_2_minutes" {
  depends_on = [oci_core_instance.ScarlettVM]
  create_duration   = "120s"
}

resource "null_resource" "generate-inventory" {

  provisioner "local-exec" {
    command = <<-EOT
      echo [New-Servers] >> inventory
      echo ${oci_core_instance.ScarlettVM.display_name} ansible_host=${oci_core_instance.ScarlettVM.public_ip} ansible_user=opc ansible_ssh_private_key_file=~/.ssh/id_rsa >> inventory
      echo ${oci_core_instance.ZabbixVM.display_name} ansible_host=${oci_core_instance.ZabbixVM.public_ip} ansible_user=opc ansible_ssh_private_key_file=~/.ssh/id_rsa >> inventory
    EOT
  }
  depends_on = [time_sleep.wait_2_minutes]
}
resource "null_resource" "execute-playbook" {

  provisioner "local-exec" {
    command = "ansible-playbook -i inventory install-httpd.yml"
  }
  depends_on = [null_resource.generate-inventory]
}
