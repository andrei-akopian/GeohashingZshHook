Fetch script for https://geohashing.info/ and https://geohashing.site/

Setup: instead of chron job, terminal is the geohashing trigger. There is a state machine state stored in share folder. fetch -> show to user -> shown to user.

Every time the script executes, it attempts to perform the next step of the state machine initially in the background. requests are the slowst part and fail if no wifi etc. is available. On next terminal (.zshrc load) the computed result is shown to the user.
