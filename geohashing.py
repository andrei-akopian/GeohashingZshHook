cat ~/bin/geohashing.py
#!/usr/bin/env python3

import datetime
import requests
from hashlib import md5
import math
from itertools import product
import sys
import argparse


# Websites that return the Dow Jones index in plain text
DOW_JONES_SOURCES = [
    "http://geo.crox.net/djia/",
    "http://www1.geo.crox.net/djia/",
    "http://www2.geo.crox.net/djia/",
    "http://carabiner.peeron.com/xkcd/map/data/",
]


def get_dow_jones(east=False, date=None):
    """
    Retrieve the Dow Jones value used for geohashing.
    """

    if date is None:
        date = datetime.date.today()

    # 30W rule
    if east:
        date += datetime.timedelta(days=-1)

    date_string = date.strftime("%Y/%m/%d")

    for url in DOW_JONES_SOURCES:
        try:
            r = requests.get(url + date_string, timeout=5)
        except requests.exceptions.RequestException:
            continue

        if r.status_code == 200:
            return r.text.strip()

    raise RuntimeError(
        "Could not retrieve Dow Jones value from any source."
    )


def get_hash(east=False, date=None, dow_jones=None):
    """
    Return the MD5 hash used for geohashing.
    """

    if date is None:
        date = datetime.date.today()

    if dow_jones is None:
        dow_jones = get_dow_jones(east, date)

    dow_jones = str(dow_jones)
    date_string = date.strftime("%Y-%m-%d")

    return md5(
        date_string.encode() + b"-" + dow_jones.encode()
    ).hexdigest()


def hash_to_location(u_lat, u_lon, md5_hash):
    """
    Convert a hash into geohash coordinates.
    """

    h1 = md5_hash[:16]
    h2 = md5_hash[16:]

    lat = str(int(u_lat)) + str(
        float.fromhex("0." + h1)
    )[1:]

    lon = str(int(u_lon)) + str(
        float.fromhex("0." + h2)
    )[1:]

    return float(lat), float(lon)


def geohash(lat, lon, date=None,
            dow_jones=None,
            east=None):
    """
    Calculate the standard xkcd geohash.
    """

    if east is None:
        east = lon > -30

    return hash_to_location(
        lat,
        lon,
        get_hash(east, date, dow_jones)
    )


def globalhash(date=None, dow_jones=None):
    lat, lon = geohash(
        0,
        0,
        date,
        dow_jones,
        east=True
    )

    lat = lat * 180 - 90
    lon = lon * 360 - 180

    return lat, lon


def replace_tenths(dst, src):
    """
    Replace tenths digit for centicule support.
    """

    new_tenths = int(abs(src) * 10) % 10
    old_tenths = int(abs(dst) * 10) % 10

    dst = str(dst)

    return float(
        dst.replace(
            f".{old_tenths}",
            f".{new_tenths}"
        )
    )


def haversine(lat1, lon1, lat2, lon2):
    """
    Great-circle distance in kilometers.
    """

    R = 6371.0

    phi1 = math.radians(lat1)
    phi2 = math.radians(lat2)

    dphi = math.radians(lat2 - lat1)
    dlambda = math.radians(lon2 - lon1)

    a = (
        math.sin(dphi / 2) ** 2
        + math.cos(phi1)
        * math.cos(phi2)
        * math.sin(dlambda / 2) ** 2
    )

    c = 2 * math.atan2(
        math.sqrt(a),
        math.sqrt(1 - a)
    )

    return R * c


def closest_geohash(lat,
                    lon,
                    date=None,
                    dow_jones=None,
                    east=None,
                    centicule=False):
    """
    Search neighboring graticules and return
    the nearest hash point.
    """

    candidates = []

    for dlat, dlon in product(
        [-1, 0, 1],
        repeat=2
    ):

        grat_lat = int(lat) + dlat
        grat_lon = int(lon) + dlon

        hlat, hlon = geohash(
            grat_lat,
            grat_lon,
            date,
            dow_jones,
            east
        )

        if centicule:
            hlat = replace_tenths(
                hlat,
                lat
            )
            hlon = replace_tenths(
                hlon,
                lon
            )

        distance = haversine(
            lat,
            lon,
            hlat,
            hlon
        )

        candidates.append({
            "lat": hlat,
            "lon": hlon,
            "distance": distance,
            "graticule": (
                grat_lat,
                grat_lon
            )
        })

        gh_lat, gh_lon = globalhash(date, dow_jones)
        distance = haversine(
            lat,
            lon,
            gh_lat,
            gh_lon
        )

        candidates.append({
            "lat": gh_lat,
            "lon": gh_lon,
            "distance": distance,
            "graticule": "global"
        })

    return min(
        candidates,
        key=lambda x: x["distance"]
    )


#
# Command line interface
#

parser = argparse.ArgumentParser(
    description="xkcd geohashing utility"
)

parser.add_argument(
    "latitude",
    type=float
)

parser.add_argument(
    "longitude",
    type=float
)

parser.add_argument(
    "-d",
    "--date",
    help="YYYY-MM-DD"
)

parser.add_argument(
    "-j",
    "--dow-jones",
    type=float
)

parser.add_argument(
    "--30w",
    choices=("e", "east", "w", "west")
)

parser.add_argument(
    "-g",
    "--global",
    dest="globalhash",
    action="store_true"
)

parser.add_argument(
    "-c",
    "--closest",
    action="store_true",
    help="Find nearest neighboring hash"
)

parser.add_argument(
    "--centicule",
    action="store_true"
)

parser.add_argument(
    "-s",
    "--simple",
    action="store_true"
)

args = parser.parse_args()


#
# Parse arguments
#

if args.date:
    try:
        args.date = datetime.datetime.strptime(
            args.date,
            "%Y-%m-%d"
        ).date()
    except ValueError:
        print(
            "Date must be YYYY-MM-DD"
        )
        sys.exit(1)

if args.__dict__["30w"] in ("e", "east"):
    east = True
elif args.__dict__["30w"] in ("w", "west"):
    east = False
else:
    east = None


#
# Perform calculation
#

print("Getting Todays Geohash")
if args.globalhash:
    lat, lon = globalhash(
        args.date,
        args.dow_jones
    )

    print(f"{lat:.6f}")
    print(f"{lon:.6f}")
    sys.exit(0)


if args.closest:

    result = closest_geohash(
        args.latitude,
        args.longitude,
        args.date,
        args.dow_jones,
        east,
        args.centicule
    )

    lat = result["lat"]
    lon = result["lon"]

    if args.simple:
        print(f"{lat}")
        print(f"{lon}")
        print(f"{result['distance']:.2f}")
        sys.exit(0)

    print(
        f"Nearest hash: "
        f"{lat:.6f}, {lon:.6f}"
    )

    print(
        f"Distance: "
        f"{result['distance']:.2f} km"
    )

    print(
        "Graticule:",
        result["graticule"]
    )

else:

    lat, lon = geohash(
        args.latitude,
        args.longitude,
        args.date,
        args.dow_jones,
        east
    )

    if args.centicule:
        lat = replace_tenths(
            lat,
            args.latitude
        )
        lon = replace_tenths(
            lon,
            args.longitude
        )

    if args.simple:
        print(lat)
        print(lon)
        sys.exit(0)

    print(f"Latitude:  {lat}")
    print(f"Longitude: {lon}")


print()
print("Google Maps:")
print(
    f"https://www.google.com/maps/search/?api=1&query={lat},{lon}"
)

print()
print("OpenStreetMap:")
print(
    f"https://www.openstreetmap.org/?mlat={lat}&mlon={lon}&zoom=10"
)
print(f"https://geohashing.info/t:map/g:{lat},{lon}/c:{lat},{lon}/z:9")
