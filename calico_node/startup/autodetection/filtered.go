// Copyright (c) 2016 Tigera, Inc. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
package autodetection

import (
	log "github.com/Sirupsen/logrus"
	"github.com/projectcalico/libcalico-go/lib/net"
)

// FilteredEnumeration performs basic IP and IPNetwork discovery by enumerating
// all interfaces and filtering in/out based on the supplied filter regex.
func FilteredEnumeration(incl, excl []string, version int) (*Interface, *net.IPNet, error) {
	interfaces, err := GetInterfaces(incl, excl, version)
	if err != nil {
		return nil, nil, err
	}

	// Find the first interface with a valid IP address and network.
	// We initialise the IP with the first valid IP that we find just in
	// case we don't find an IP *and* network.
	for _, i := range interfaces {
		log.WithField("Name", i.Name).Debug("Check interface")
		for _, c := range i.Cidrs {
			log.WithField("CIDR", c).Debug("Check address")
			if c.IP.IsGlobalUnicast() {
				return &i, &c, nil
			}
		}
	}

	return nil, nil, nil
}
