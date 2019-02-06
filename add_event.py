#!/usr/bin/env python

import requests
import time
import json
import sys
import os.path
import os

if len(sys.argv) < 3:
    print ("Error expected 2 arguments:\n\t{bin} <device> <risk_type>\n\t    e.g. {bin} andys-mac comprimised.creds".format(bin=sys.argv[0]))
    sys.exit(1)

base = os.getenv("HOME") + "/private"
KEY = base + "/key.me"
CERT = base + "/cert.me"
CA = base + "/cert.ca"

if not os.path.isfile(KEY)  or not os.path.isfile(CERT) or not os.path.isfile(CA):
    print("Error need creds {}, {} and {}".format(KEY, CERT, CA))
    sys.exit(2)

device = sys.argv[1]
risk_type = sys.argv[2]

now = time.time()

exists_query = {
   "class": "uk.gov.gchq.gaffer.operation.impl.get.GetElements",
   "input": [
      {
         "vertex": device,
         "class": "uk.gov.gchq.gaffer.operation.data.EntitySeed"
      }
   ]
}

add_data = {
    "class": "uk.gov.gchq.gaffer.operation.impl.add.AddElements",
    "validate": True,
    "skipInvalidElements": False,
    "input": [
	{
	    "class": "uk.gov.gchq.gaffer.data.element.Edge",
	    "group": "devicerisk",
	    "source": device,
	    "destination": risk_type,
	    "directed": True,
	    "properties": {
                "time": {
		     "uk.gov.gchq.gaffer.time.RBMBackedTimestampSet": {
 		         "timeBucket" : "MINUTE",
			 "timestamps" : [ now ]
		     }
	        }
            }
        }
    ]
}

add_device = {
    "class": "uk.gov.gchq.gaffer.operation.impl.add.AddElements",
    "validate": True,
    "skipInvalidElements": False,
    "input": [
	{
	    "vertex": device,
        "group": "device",
        "properties": {
            "count": 1
        },
        "class": "uk.gov.gchq.gaffer.data.element.Entity"
        }
    ]
}

with requests.Session() as s:
    s.cert = (CERT,KEY)
    s.verify = CA

    url = "https://analytics.trustnetworks.com/gaffer/rest/v2/graph/operations/execute"
    headers = {'content-type':'application/json'}
    query = json.dumps(exists_query)
    response = s.post(url,query, headers=headers)
    if len(response.json()) == 0:
        add_dev= json.dumps(add_device)
        response = s.post(url,add_cat, headers=headers)
        print("Adding device Status:", response.status_code)

    data = json.dumps(add_data)
    response = s.post(url, data, headers=headers)

    print "Status:",response.status_code
    print response.text
