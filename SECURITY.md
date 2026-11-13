# Reporting a problem

MacUnclog deletes files and stops processes, so a bug that removes or stops the wrong thing counts as a security issue.

If MacUnclog deleted something it shouldn't have, stopped a process it shouldn't have, or could be made to do so, please report it privately through GitHub's "Report a vulnerability" button on the Security tab of this repository, rather than in a public issue.

Include, if you can:

- what MacUnclog deleted or stopped, with the path or process;
- the entry for that run in `~/Library/Application Support/MacUnclog/History`;
- the output of `MacUnclog.app/Contents/MacOS/MacUnclog --scan` for the category involved.

These bugs get fixed before anything else.
