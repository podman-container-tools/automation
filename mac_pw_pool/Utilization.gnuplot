
# Intended to be run like: `gnuplot -p -c Utilization.gnuplot`
# Requires a file named `utilization.csv` produced by commands
# in `Cron.sh`.
#
# Format Ref: http://gnuplot.info/docs_5.5/Overview.html

set terminal png enhanced rounded size 1400,800 nocrop
set output 'html/utilization.png'

set title "Runners Online & Active"

set xdata time
set timefmt "%Y-%m-%dT%H:%M:%S+00:00"
set xtics nomirror rotate timedate
set xlabel "time/date"
set xrange [(system("date -u -Iseconds -d '26 hours ago'")):(system("date -u -Iseconds"))]

set ylabel "Number of Runners"
set ytics border nomirror numeric
# Not practical to lookup $DH_PFX from pw_lib.sh
set yrange [0:(system("grep -E '^[a-zA-Z0-9]+-[0-9]' dh_status.txt | wc -l") + 1)]

set datafile separator comma
set grid

plot 'utilization.csv' using 1:2         title "Online" pt 7 ps 2, \
                    '' using 1:(($3-$4)) title "Active" with lines lw 2
