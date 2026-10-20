# The examples of OneK8s design section 3.1 ("VNets and address plan") must hold.

run "prd_matches_design" {
  command = plan

  variables {
    environment = "prd"
  }

  assert {
    condition     = output.environment_prefix == "10.48.0.0/12"
    error_message = "prd must be 10.48.0.0/12."
  }

  assert {
    condition     = output.zones["int-fi"].prefix == "10.49.0.0/17" && output.zones["ext-fi"].prefix == "10.49.128.0/17"
    error_message = "int-fi / ext-fi prefixes differ from the design."
  }

  assert {
    condition     = output.zones["int-fi"].frontend == "10.49.0.0/18" && output.zones["int-fi"].backend == "10.49.64.0/18"
    error_message = "int-fi frontend / backend /18 differ from the design."
  }

  assert {
    condition = (
      output.zones["int-fi"].slots["sl-az1"] == "10.49.0.0/20" &&
      output.zones["int-fi"].slots["sl-az2"] == "10.49.16.0/20" &&
      output.zones["int-fi"].slots["sl-az3"] == "10.49.32.0/20" &&
      output.zones["int-fi"].slots["edge"] == "10.49.48.0/20" &&
      output.zones["int-fi"].slots["sf"] == "10.49.64.0/20"
    )
    error_message = "int-fi /20 slots differ from the design."
  }

  assert {
    condition     = toset(output.cells["sl-az1"].address_spaces) == toset(["10.48.0.0/20", "10.49.0.0/20", "10.49.128.0/20", "10.50.0.0/20", "10.50.128.0/20"])
    error_message = "vnet-prd-sl-az1 address spaces differ from the design."
  }
}

run "dev_matches_design" {
  command = plan

  variables {
    environment = "dev"
  }

  assert {
    condition     = output.environment_prefix == "10.16.0.0/12" && output.country_prefixes["fi"] == "10.17.0.0/16" && output.country_prefixes["se"] == "10.18.0.0/16"
    error_message = "dev prefixes differ from the design."
  }
}

run "new_country_does_not_move_existing_zones" {
  command = plan

  variables {
    environment = "dev"
    countries   = { fi = 1, se = 2, no = 3 }
  }

  assert {
    condition     = output.zones["int-fi"].prefix == "10.17.0.0/17" && output.zones["int-no"].prefix == "10.19.0.0/17"
    error_message = "Adding a country must not change existing zones (R5)."
  }
}
