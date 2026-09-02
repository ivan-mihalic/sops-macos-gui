package gobridge

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestInspectConfigRulesResolvesAnchorsAndGoverns(t *testing.T) {
	dir := t.TempDir()
	conf := filepath.Join(dir, ".sops.yaml")
	a := "age1ccsm6kw9f5vx4znq75wufan68wtt6uzhn3aka7zpnyr252e87aeqt2pg0m"
	b := "age1fz69490r89f7gvuhcypsqn6v2yquxdw7pgryw0ujqrmx009qg4yspxs2de"
	c := "age1qrcuga3zl5kxkdmmvcm3elwmgs86tjfekujf90fqq775lyu2953s4nn27e"
	yaml := "keys:\n" +
		"  - &mac_studio " + a + "\n" +
		"  - &macbook " + b + "\n" +
		"  - &vps_prod " + c + "\n" +
		"creation_rules:\n" +
		"  # Produkční tajemství čte i server.\n" +
		"  - path_regex: secrets/prod\\.sops\\.env$\n" +
		"    key_groups:\n" +
		"      - age: [*mac_studio, *macbook, *vps_prod]\n" +
		"  - path_regex: \\.sops\\.(env|ya?ml|json)$\n" +
		"    age: " + a + "," + b + "\n"
	if err := os.WriteFile(conf, []byte(yaml), 0o600); err != nil {
		t.Fatal(err)
	}
	prod := filepath.Join(dir, "secrets", "prod.sops.env")
	local := filepath.Join(dir, "secrets", "local.sops.env")

	got, err := InspectConfigRules(conf, []string{prod, local})
	if err != nil {
		t.Fatal(err)
	}

	if len(got.Keys) != 3 || got.Keys[0].Name != "mac_studio" || got.Keys[0].Recipient != a {
		t.Fatalf("keys = %+v", got.Keys)
	}
	if len(got.Rules) != 2 {
		t.Fatalf("rules = %+v", got.Rules)
	}
	r0 := got.Rules[0]
	if !r0.UsesKeyGroups || !r0.UsesAnchors || r0.Comment != "Produkční tajemství čte i server." {
		t.Fatalf("rule0 = %+v", r0)
	}
	if len(r0.Recipients) != 3 || r0.Recipients[2].Name != "vps_prod" || r0.Recipients[2].Recipient != c {
		t.Fatalf("rule0 recipients = %+v", r0.Recipients)
	}
	r1 := got.Rules[1]
	if r1.UsesAnchors || len(r1.Recipients) != 2 || r1.Recipients[0].Name != "" || r1.Recipients[0].Recipient != a {
		t.Fatalf("rule1 = %+v", r1)
	}
	if got.GovernedBy[prod] != 0 || got.GovernedBy[local] != 1 {
		t.Fatalf("governedBy = %v", got.GovernedBy)
	}
}

func TestInspectConfigRulesNoRulesKeyIsEmptyNotNil(t *testing.T) {
	dir := t.TempDir()
	conf := filepath.Join(dir, ".sops.yaml")
	if err := os.WriteFile(conf, []byte("keys: []\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	got, err := InspectConfigRules(conf, nil)
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(got)
	if strings.Contains(string(raw), "null") {
		t.Fatalf("nil slice leaked: %s", raw)
	}
}
