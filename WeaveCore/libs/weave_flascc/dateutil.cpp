/* ***** BEGIN LICENSE BLOCK *****
 *
 * This file is part of the Weave API.
 *
 * The Initial Developer of the Weave API is the Institute for Visualization
 * and Perception Research at the University of Massachusetts Lowell.
 * Portions created by the Initial Developer are Copyright (C) 2008-2012
 * the Initial Developer. All Rights Reserved.
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this file,
 * You can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * ***** END LICENSE BLOCK ***** */

#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "AS3/AS3.h"
#include "tracef.h"

void dates_parse() __attribute((used,
            annotate("as3sig:public function dates_parse(dates:Array, fmt:String):Array"),
            annotate("as3package:weave.flascc")));

void dates_parse()
{
    size_t dates_n = 0;
    char *fmt;
    inline_nonreentrant_as3(
            "%0 = dates.length;"
            "%1 = CModule.mallocString(fmt);"
            "var output:Array = new Array(dates.length);"
            : "=r"(dates_n), "=r"(fmt)
    );

    size_t idx;
    char* date_str;
    struct tm tm;
    memset(&tm, 0, sizeof(struct tm));
    for (idx = 0; idx < dates_n; idx++)
    {
        inline_nonreentrant_as3(
            "%0 = CModule.mallocString(String(dates[%1]));"
            : "=r"(date_str) : "r"(idx)
        );

        if (strptime(date_str, fmt, &tm))
        {
			inline_nonreentrant_as3(
				"output[%0] = new Date(%1,%2,%3,%4,%5,%6);"
				: : "r"(idx),
				 "r"(tm.tm_year + 1900),
				 "r"(tm.tm_mon),
				 "r"(tm.tm_mday),
				 "r"(tm.tm_hour),
				 "r"(tm.tm_min),
				 "r"(tm.tm_sec)
			);
        }
        else
        {
        	inline_nonreentrant_as3("output[%0] = null;" : : "r"(idx));
        }
        free(date_str);
    }
    free(fmt);

    AS3_ReturnAS3Var(output);
}


size_t dates_detect_c(char* dates[], size_t dates_n, char* formats[], size_t* formats_n);

void dates_detect() __attribute((used,
            annotate("as3sig:public function dates_detect(dates:Array, formats:Array):Array"),
            annotate("as3package:weave.flascc")));

void dates_detect()
{
    size_t dates_n = 0;
    size_t formats_n = 0;
    char** dates;
    char** formats;

    inline_nonreentrant_as3(
            "%0 = dates.length;"
            "%1 = formats.length;"
            "var dates_ptr:int = CModule.malloc(dates.length * 4);"
            "var formats_ptr:int = CModule.malloc(formats.length * 4);"
            "%2 = dates_ptr;"
            "%3 = formats_ptr;"
            : "=r"(dates_n), "=r"(formats_n), "=r"(dates), "=r"(formats)
    );

    size_t idx;
    char* tmp;

    for (idx = 0; idx < dates_n; idx++)
    {
        inline_nonreentrant_as3(
                "%0 = CModule.mallocString(String(dates[%1]));"
                : "=r"(tmp) : "r"(idx)
        );
        dates[idx] = tmp;
    }

    for (idx = 0; idx < formats_n; idx++)
    {
        inline_nonreentrant_as3(
                "%0 = CModule.mallocString(String(formats[%1]));"
                : "=r"(tmp) : "r"(idx)
        );
        formats[idx] = tmp;
    }

    dates_detect_c(dates, dates_n, formats, &formats_n);

    /* Free the dates */
    for (idx = 0; idx < dates_n; idx++)
    {
        free(dates[idx]);
    }
    free(dates);

    inline_nonreentrant_as3(
            "var output:Array = new Array(%0)"
            : : "r"(formats_n)
    );

    size_t len;
    for (idx = 0; idx < formats_n; idx++)
    {
        len = strlen(formats[idx]);
        inline_as3(
                "ram.position = %0;"
                "var formatStr:String = ram.readUTFBytes(%1);"
                "output[%2] = formatStr;"
                : : "r"(formats[idx]), "r"(len), "r"(idx)
        );
        free(formats[idx]);
    }
    free(formats);
    AS3_ReturnAS3Var(output);
}

/**
 * Filter a list of date format strings down to only those which return a valid result for all dates.
 * @param dates An array of date strings to test against.
 * @param dates_n The length of dates.
 * @param formats The array of candidate format strings. This will be altered
 *                to only contain format strings which work for all dates provided.
 * @param formats_n A pointer to the length of the candidate format string list. This will be altered to match the length of the filtered output.
 * @return The number of formats which were valid for all input strings.
 */

size_t dates_detect_c(char* dates[], size_t dates_n, char* formats[], size_t *formats_n)
{
    /* fmt_idx needs to be int so we can let it go negative */
    int row_idx, fmt_idx;
    size_t formats_remaining = *formats_n;
    struct tm tmp_time;
    for (row_idx = 0; row_idx < dates_n; row_idx++)
    {
        if (dates[row_idx] == NULL) continue;
        for (fmt_idx = 0; fmt_idx < formats_remaining; fmt_idx++)
        {
            if (formats[fmt_idx] == NULL)
            {
                formats_remaining = fmt_idx+1;
                break;
            }
            //tracef("strptime(%s, %s, ...)\n", dates[row_idx], formats[fmt_idx]);
            if (strptime(dates[row_idx], formats[fmt_idx], &tmp_time) == NULL)
            {
                /*
                 * Put the last entry in this slot, make the last entry NULL,
                 * and reduce the length to test. Decrementing fmt_idx ensures
                 * that we test the entry that is now at this slot on the next pass.
                 */
                formats_remaining--;
                free(formats[fmt_idx]);
                formats[fmt_idx] = formats[formats_remaining];
                formats[formats_remaining] = NULL;
                fmt_idx--;
            }
        }
    }
    return *formats_n = formats_remaining;
}