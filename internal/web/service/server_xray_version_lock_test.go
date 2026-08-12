package service

import "testing"

func TestGetXrayVersionsLockedToPinnedVersion(t *testing.T) {
	versions, err := (&ServerService{}).GetXrayVersions()
	if err != nil {
		t.Fatalf("GetXrayVersions returned error: %v", err)
	}

	want := []string{"v26.6.27"}
	if len(versions) != len(want) {
		t.Fatalf("versions = %v, want %v", versions, want)
	}
	for i := range want {
		if versions[i] != want[i] {
			t.Fatalf("versions = %v, want %v", versions, want)
		}
	}
}

func TestUpdateXrayRejectsUnpinnedVersions(t *testing.T) {
	for _, version := range []string{"v26.7.11", "v26.7.28"} {
		t.Run(version, func(t *testing.T) {
			err := (&ServerService{}).UpdateXray(version)
			if err == nil {
				t.Fatal("UpdateXray accepted an unpinned version")
			}
		})
	}
}
