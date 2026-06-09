# Copyright 2023 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import argparse
import datetime
import re
from collections import defaultdict
import subprocess
import shutil
from dateutil.relativedelta import relativedelta

def check_gh_command():
    """
    Pretty much everything is processed from `gh`
    Check that the `gh` command is in the path before anything else
    """
    if not shutil.which('gh'):
        print("Error: The `gh` command is not available in the PATH.")
        print("Please install the GitHub CLI (https://cli.github.com/) and try again.")
        exit(1)

def duration_ago(dt):
    """
    Humanize duration outputs
    """
    delta = relativedelta(datetime.datetime.now(), dt)
    if delta.years > 0:
        return f"{delta.years} year{'s' if delta.years > 1 else ''} ago"
    elif delta.months > 0:
        return f"{delta.months} month{'s' if delta.months > 1 else ''} ago"
    elif delta.days > 0:
        return f"{delta.days} day{'s' if delta.days > 1 else ''} ago"
    elif delta.hours > 0:
        return f"{delta.hours} hour{'s' if delta.hours > 1 else ''} ago"
    elif delta.minutes > 0:
        return f"{delta.minutes} minute{'s' if delta.minutes > 1 else ''} ago"
    else:
        return "just now"

def parse_version(version):
    """
    Parse version assuming it is in the form of v1.2.3
    """
    pattern = r"v(\d+)\.(\d+)\.(\d+)"
    match = re.match(pattern, version)
    if match:
        major, minor, patch =  map(int, match.groups())
        return (major, minor, patch)

def end_of_life_grouped_versions(versions):
    """
    Calculate the end of life date for a minor release version according to : https://kubernetes-csi.github.io/docs/project-policies.html#support

    The input is an array of tuples of:
      * grouped versions (e.g. 1.0, 1.1)
      * array of that contains all versions and their release date (e.g. 1.0.0, 01-01-2013)

    versions structure example :
      [((3, 5), [('v3.5.0', datetime.datetime(2023, 4, 27, 22, 28, 6))]),
       ((3, 4),
       [('v3.4.1', datetime.datetime(2023, 4, 5, 17, 41, 15)),
        ('v3.4.0', datetime.datetime(2022, 12, 27, 23, 43, 41))])]
    """
    supported_versions = []
    # Prepare dates for later calculation
    now          = datetime.datetime.now()
    one_year     = datetime.timedelta(days=365)
    three_months = datetime.timedelta(days=90)

    # get the newer versions on top
    sorted_versions_list = sorted(versions.items(), key=lambda x: x[0], reverse=True)

    # the latest version is always supported no matter the release date
    latest = sorted_versions_list.pop(0)
    supported_versions.append(latest[1][-1])

    for v in sorted_versions_list:
        first_release = v[1][-1]
        last_release  = v[1][0]
        # if the release is less than a year old we support the latest patch version
        if now - first_release[1] < one_year:
            supported_versions.append(last_release)
        # if the main release is older than a year and has a recent path, this is supported
        elif now - last_release[1] < three_months:
            supported_versions.append(last_release)
    return supported_versions

def get_release_docker_image(repo, version):
    """
    Extract docker image name from the release page documentation
    """
    output = subprocess.check_output(['gh', 'release', '-R', repo, 'view', version], text=True)
    #Extract matching image name excluding `
    match = re.search(r"docker pull ([\.\/\-\:\w\d]*)", output)
    docker_image = match.group(1) if match else ''
    return((version, docker_image))

def get_versions_from_releases(repo):
    """
    Using `gh` cli get the github releases page details then
    create a list of grouped version on major.minor 
    and for each give all major.minor.patch with release dates
    """
    # Run the `gh release` command to get the release list
    output = subprocess.check_output(['gh', 'release', '-R', repo, 'list'], text=True)
    # Parse the output and group by major and minor version numbers
    versions = defaultdict(lambda: [])
    for line in output.strip().split('\n'):
        parts = line.split('\t')
        # pprint.pprint(parts)
        version = parts[0]
        parsed_version = parse_version(version)
        if parsed_version is None:
            continue
        major, minor, patch = parsed_version

        published = datetime.datetime.strptime(parts[3], '%Y-%m-%dT%H:%M:%SZ')
        versions[(major, minor)].append((version, published))
    return(versions)


def main():
    manual = """
    This script lists the supported versions Github releases according to https://kubernetes-csi.github.io/docs/project-policies.html#support
    It has been designed to help to update the tables from : https://kubernetes-csi.github.io/docs/sidecar-containers.html\n\n
    It can take multiple repos as argument, for all CSI sidecars details you can run:
    ./get_supported_version_csi-sidecar.py -R kubernetes-csi/external-attacher -R kubernetes-csi/external-provisioner -R kubernetes-csi/external-resizer -R kubernetes-csi/external-snapshotter -R kubernetes-csi/livenessprobe -R kubernetes-csi/node-driver-registrar -R kubernetes-csi/external-health-monitor\n
    With the output you can then update the documentation manually.
    """
    parser = argparse.ArgumentParser(formatter_class=argparse.RawDescriptionHelpFormatter, description=manual)
    parser.add_argument('--repo', '-R', required=True, action='append', dest='repos', help='The name of the repository in the format owner/repo.')
    parser.add_argument('--display', '-d', action='store_true', help='(default) Display EOL versions with their dates', default=True)
    parser.add_argument('--doc', '-D', action='store_true', help='Helper to https://kubernetes-csi.github.io/docs/ that prints Docker image for each EOL version')

    args = parser.parse_args()

    # Verify pre-reqs
    check_gh_command()

    # Process all repos
    for repo in args.repos:
        versions = get_versions_from_releases(repo)
        eol_versions = end_of_life_grouped_versions(versions)

        if args.display:
            print(f"Supported versions with release date and age of `{repo}`:\n")
            for version in eol_versions:
                print(f"{version[0]}\t{version[1].strftime('%Y-%m-%d')}\t{duration_ago(version[1])}")

        # TODO : generate proper doc output for the tables of: https://kubernetes-csi.github.io/docs/sidecar-containers.html
        if args.doc:
            print("\nSupported Versions with docker images for each end of life version:\n")
            for version in eol_versions:
                _, image = get_release_docker_image(repo, version[0])
                print(f"{version[0]}\t{image}")
        print()

if __name__ == '__main__':
    main()
