#!/bin/sh
##############################################################################
# Copyright (c) 2013-14: fritz-hh from Github (https://github.com/fritz-hh)
# Copyright (c) 2014 Daniel Berthereau
##############################################################################

# Import required scripts
. "`dirname $0`/src/config.sh"

# Set variables corresponding to the input parameters
ARGUMENTS="$@"

START=`date +%s`

usage() {
	cat << EOF
--------------------------------------------------------------------------------------
Script aimed at generating a searchable PDF file from a PDF file containing only images.
(The script performs optical character recognition of each respective page using the
tesseract engine)

Copyright: fritz-hh  from Github (https://github.com/fritz-hh)
Version: $VERSION

Usage: OCRmyPDF.sh  [-h] [-v] [-g] [-k] [-d] [-c] [-i] [-o dpi] [-f] [-s] [-l language] [-j jobs] [-C filename] inputfile outputfile
       OCRmyPDF.sh  [-h] [-v] [-g] [-k] [-d] [-c] [-i] [-o dpi] [-f] [-s] [-l language] [-j jobs] [-C filename] -a -p outputfile inputfiles

-h : Display this help message
-v : Increase the verbosity (this option can be used more than once) (e.g. -vvv)
-k : Do not delete the temporary files
-g : Activate debug mode:
     - Generates a PDF file containing each page twice (once with the image, once without the image
       but with the OCRed text as well as the detected bounding boxes)
     - Set the verbosity to the highest possible
     - Do not delete the temporary files
-d : Deskew each page before performing OCR
-c : Clean each page before performing OCR
-i : Incorporate the cleaned image in the final PDF file (by default the original image
     image, or the deskewed image if the -d option is set, is incorporated)
-o : If the resolution of an image is lower than dpi value provided as argument, provide the OCR engine with
     an oversampled image having the latter dpi value. This can improve the OCR results but can lead to a larger output PDF file.
     (default: no oversampling performed)
-f : Force to OCR the whole document, even if some page already contain font data.  Any text data will be rendered
     to raster format and then fed through OCR.
     (which should not be the case for PDF files built from scanned images)
-s : If pages contain font data, do not perform processing on that page, but include the page in the final output.
-l : Set the language of the PDF file in order to improve OCR results (default "eng")
     Any language supported by tesseract is supported (Tesseract uses 3-character ISO 639-2 language codes)
     Multiple languages may be specified, separated by '+' characters.
-j : Maximum number of parallel tasks to run.
-a : Use a list of images as input instead of a pdf file. In that case, the
     input should be a list of file or a string to be expanded by shell like "image_*.ext"
     and the output should be set with the -o option.
-p : Output file (required with -a, else forbidden)
-C : Pass an additional configuration file to the tesseract OCR engine.
     (this option can be used more than once)
     Note 1: The configuration file must be available in the "tessdata/configs" folder of your tesseract installation
inputfile  : PDF file (or list of images when -a is used) to be OCRed
outputfile : The PDF/A file that will be generated (except if -p is used)
--------------------------------------------------------------------------------------
EOF
}


#################################################
# Get an absolute path from a relative path to a file
#
# Param1 : Relative path
# Returns: 1 if the folder in which the file is located does not exist
#          0 otherwise
#################################################
absolutePath() {
	local wdsave absolutepath
	wdsave="$(pwd)"
	! cd "$(dirname "$1")" 1> /dev/null 2> /dev/null && return 1
	absolutepath="$(pwd)/$(basename "$1")"
	cd "$wdsave"
	echo "$absolutepath"
	return 0
}


# Initialization the configuration parameters with default values
VERBOSITY="$LOG_ERR"		# default verbosity level
LANGUAGE="eng"			# default language of the PDF file (required to get good OCR results)
KEEP_TMP="0"			# 0=no, 1=yes (keep the temporary files)
PREPROCESS_DESKEW="0"		# 0=no, 1=yes (deskew image)
PREPROCESS_CLEAN="0"		# 0=no, 1=yes (clean image to improve OCR)
PREPROCESS_CLEANTOPDF="0"	# 0=no, 1=yes (put cleaned image in final PDF)
OVERSAMPLING_DPI="0"		# 0=do not perform oversampling (dpi value under which oversampling should be performed)
PDF_NOIMG="0"			# 0=no, 1=yes (generates each PDF page twice, with and without image)
FORCE_OCR="0"			# 0=do not force, 1=force (force to OCR the whole document, even if some page already contain font data)
SKIP_TEXT="0"			# 0=do not skip text pages, 1=skip text pages
USE_IMAGES="0"                  # 0=no, 1=yes (use existing images)
TESS_CFG_FILES=""		# list of additional configuration files to be used by tesseract
JOBS=""                         # Parameter for parallel jobs
FILE_OUTPUT_PDFA=""             # Output file

# Parse optional command line arguments
while getopts ":hvgkdcio:fsl:j:ap:C:" opt; do
	case $opt in
		h) usage ; exit 0 ;;
		v) VERBOSITY=$(($VERBOSITY+1)) ;;
		k) KEEP_TMP="1" ;;
		g) PDF_NOIMG="1"; VERBOSITY="$LOG_DEBUG"; KEEP_TMP="1" ;;
		d) PREPROCESS_DESKEW="1" ;;
		c) PREPROCESS_CLEAN="1" ;;
		i) PREPROCESS_CLEANTOPDF="1" ;;
		o) OVERSAMPLING_DPI="$OPTARG" ;;
		f) FORCE_OCR="1" ;;
		s) SKIP_TEXT="1" ;;
		l) LANGUAGE="$OPTARG" ;;
		j) JOBS="--jobs $OPTARG" ;;
                a) USE_IMAGES="1" ;;
                p) FILE_OUTPUT_PDFA="$OPTARG" ;;
		C) TESS_CFG_FILES="$OPTARG $TESS_CFG_FILES" ;;
		\?)
			echo "Invalid option: -$OPTARG"
			usage
			exit $EXIT_BAD_ARGS ;;
		:)
			echo "Option -$OPTARG requires an argument"
			usage
			exit $EXIT_BAD_ARGS ;;
	esac
done

# Check force and skip options.
if [ "$SKIP_TEXT" = "1" -a "$FORCE_OCR" = "1" ]; then
        echo "Options -f and -s are mutually exclusive; choose one or the other"
        usage
        exit $EXIT_BAD_ARGS
fi

# Check -a and -p options.
if [ "$USE_IMAGES" = "0" ] && [ -n "$FILE_OUTPUT_PDFA" ]; then
        echo "Option -p cannot be used without the option -a."
        usage
        exit $EXIT_BAD_ARGS
elif [ "$USE_IMAGES" = "1" ] && [ -z "$FILE_OUTPUT_PDFA" ]; then
        echo "Option -p is required when the option -a is used."
        usage
        exit $EXIT_BAD_ARGS
fi

# Remove the optional arguments parsed above.
shift $((OPTIND-1))

# Check if the number of mandatory parameters provided is as expected
if [ "$USE_IMAGES" = "0" ] && [ "$#" -ne 2 ]; then
        echo "Exactly two mandatory arguments (input and output files) shall be provided ($# arguments provided)."
        usage
        exit $EXIT_BAD_ARGS
elif [ "$USE_IMAGES" = "1" ] && [ "$#" -lt 1 ]; then
        echo "When using images files, the list of files should be provided."
        usage
        exit $EXIT_BAD_ARGS
fi

# Check files and get absolute paths.
if [ "$USE_IMAGES" = "0" ]; then
        if [ ! -f "$1" ]; then
                echo "The input file does not exist. Exiting..." && exit $EXIT_BAD_ARGS
        fi
        ! absolutePath "$1" > /dev/null \
                && echo "The folder in which the input file should be located does not exist. Exiting..." && exit $EXIT_BAD_ARGS
        FILE_INPUT_PDF="`absolutePath "$1"`"
        ! absolutePath "$2" > /dev/null \
                && echo "The folder in which the output file should be generated does not exist. Exiting..." && exit $EXIT_BAD_ARGS
        FILE_OUTPUT_PDFA="`absolutePath "$2"`"
else
        for image in "${@}"; do
                if [ ! -f "$image" ]; then
                        echo "The input file '$image' does not exist. Exiting..." && exit $EXIT_BAD_ARGS
                fi
                ! absolutePath "$image" > /dev/null \
                        && echo "The folder in which input files should be generated does not exist. Exiting..." && exit $EXIT_BAD_ARGS
        done

        FILE_INPUT_PDF=""
        ! absolutePath "$FILE_OUTPUT_PDFA" > /dev/null \
                && echo "The folder in which the output file should be generated does not exist. Exiting..." && exit $EXIT_BAD_ARGS
        FILE_OUTPUT_PDFA="`absolutePath "$FILE_OUTPUT_PDFA"`"

        [ $VERBOSITY -ge $LOG_DEBUG ] && echo "Using a list of images."
fi

# Check existing file.
[ -e "$FILE_OUTPUT_PDFA" ] && echo "The output file already exists. Exiting..." && exit 0

# Get current path and set script path as working directory.
CURRENT_PATH="`pwd`"
cd "`dirname $0`"

[ $VERBOSITY -ge $LOG_DEBUG ] && echo "$TOOLNAME version: $VERSION"
[ $VERBOSITY -ge $LOG_DEBUG ] && echo "Arguments: $ARGUMENTS"

# check if the required utilities are installed
[ $VERBOSITY -ge $LOG_DEBUG ] && echo "Checking if all dependencies are installed"
! command -v identify > /dev/null && echo "Please install ImageMagick. Exiting..." && exit $EXIT_MISSING_DEPENDENCY
! command -v parallel > /dev/null && echo "Please install GNU Parallel. Exiting..." && exit $EXIT_MISSING_DEPENDENCY
! command -v pdfimages > /dev/null && echo "Please install poppler-utils. Exiting..." && exit $EXIT_MISSING_DEPENDENCY
! command -v pdffonts > /dev/null && echo "Please install poppler-utils. Exiting..." && exit $EXIT_MISSING_DEPENDENCY
! command -v pdftoppm > /dev/null && echo "Please install poppler-utils with the option --enable-splash-output enabled. Exiting..." && exit $EXIT_MISSING_DEPENDENCY
! command -v pdfseparate > /dev/null && echo "Please install or update poppler-utils to at least 0.24.5. Exiting..." && exit $EXIT_MISSING_DEPENDENCY
[ "$PREPROCESS_CLEAN" = "1" ] && ! command -v unpaper > /dev/null && echo "Please install unpaper. Exiting..." && exit $EXIT_MISSING_DEPENDENCY
! command -v tesseract > /dev/null && echo "Please install tesseract and tesseract-data. Exiting..." && exit $EXIT_MISSING_DEPENDENCY
! command -v python2 > /dev/null && echo "Please install python v2.x. Exiting..." && exit $EXIT_MISSING_DEPENDENCY
! python2 -c 'import lxml' 2>/dev/null && echo "Please install the python library lxml. Exiting..." && exit $EXIT_MISSING_DEPENDENCY
! python2 -c 'import reportlab' 2>/dev/null && echo "Please install the python library reportlab. Exiting..." && exit $EXIT_MISSING_DEPENDENCY
! command -v gs > /dev/null && echo "Please install ghostcript. Exiting..." && exit $EXIT_MISSING_DEPENDENCY
! command -v java > /dev/null && echo "Please install java. Exiting..." && exit $EXIT_MISSING_DEPENDENCY


# ensure the right tesseract version is installed
# older versions are known to produce malformed hocr output and should not be used
# Even 3.02.01 fails in few cases (see issue #28). I decided to allow this version anyway because
# 3.02.02 is not yet available for some widespread linux distributions
reqtessversion="3.02.01"
tessversion=`tesseract -v 2>&1 | grep "tesseract" | sed s/[^0-9.]//g`
tesstooold=$(echo "`echo $tessversion | sed s/[.]//2`-`echo $reqtessversion | sed s/[.]//2` < 0" | bc)
[ "$tesstooold" = "1" ] \
	&& echo "Please install tesseract ${reqtessversion} or newer (currently installed version is ${tessversion})" && exit $EXIT_MISSING_DEPENDENCY

# ensure the right GNU parallel version is installed
# older version do not support -q flag (required to escape special characters)
reqparallelversion="20130222"
parallelversion=`parallel --minversion 0`
! parallel --minversion "$reqparallelversion" > /dev/null \
	&& echo "Please install GNU parallel ${reqparallelversion} or newer (currently installed version is ${parallelversion})" && exit $EXIT_MISSING_DEPENDENCY

# ensure pdftoppm is provided by poppler-utils, not the older xpdf version
! pdftoppm -v 2>&1 | grep -q 'Poppler' && echo "Please remove xpdf and install poppler-utils. Exiting..." && $EXIT_MISSING_DEPENDENCY



# Display the version of the tools if log level is LOG_DEBUG
if [ $VERBOSITY -ge $LOG_DEBUG ]; then
	echo "--------------------------------"
	echo "ImageMagick version:"
	identify --version
	echo "--------------------------------"
	echo "GNU Parallel version:"
	parallel --version
	echo "--------------------------------"
	echo "Poppler-utils version:"
	pdfimages -v
	pdftoppm -v
	pdffonts -v
	pdfseparate -v
	echo "--------------------------------"
	echo "unpaper version:"
	unpaper --version
	echo "--------------------------------"
	echo "tesseract version:"
	tesseract --version
	echo "--------------------------------"
	echo "python2 version:"
	python2 --version
	echo "--------------------------------"
	echo "Ghostscript version:"
	gs --version
	echo "--------------------------------"
	echo "Java version:"
	java -version
	echo "--------------------------------"
fi



# check if the languages passed to tesseract are all supported
for currentlan in `echo "$LANGUAGE" | sed 's/+/ /g'`; do
	if ! tesseract --list-langs 2>&1 | grep "^$currentlan\$" > /dev/null; then
		echo "The language \"$currentlan\" is not supported by tesseract."
		tesseract --list-langs 2>&1 | tr '\n' ' '; echo
		echo "Exiting..."
		exit $EXIT_BAD_ARGS
	fi
done



# Initialize path to temporary files using mktemp
# Goal: save tmp file in a sub-folder of the $TMPDIR environment variable (or in "/tmp" if unset)
# Unfortunately, Linux mktemp is not compatible with FreeBSD/OSX mktemp
# Linux version requires no arg
# FreeBSD requires '-t prefix' to be used so that $TMPDIR is taken into account
# But in Linux '-t template' is handled differently than in FreeBSD
# Therefore different calls must be used for Linux and for FreeBSD
prefix="$(date +"%Y%m%d_%H%M").filename.$(basename "$FILE_INPUT_PDF" | sed 's/[.][^.]*$//')"	# prefix made of date, time and pdf file name without extension
TMP_FLD=`mktemp -d 2>/dev/null || mktemp -d -t "${prefix}" 2>/dev/null`				# try Linux syntax first, if it fails try FreeBSD/OSX
if [ "$?" -ne 0 ]; then
	if [ -z "$TMPDIR" ]; then
		echo "Could not create folder for temporary files. Please ensure you have sufficient right and \"/tmp\" exists"
	else
		echo "Could not create folder for temporary files. Please ensure you have sufficient right and \"$TMPDIR\" exists"
	fi
	exit $EXIT_FILE_ACCESS_ERROR
fi
[ $VERBOSITY -ge $LOG_DEBUG ] && echo "Created temporary folder: \"$TMP_FLD\""

FILE_TMP="${TMP_FLD}/tmp.txt"						# temporary file with a very short lifetime (may be used for several things)
FILE_INPUT_FILES="${TMP_FLD}/input-files.txt"                           # temporary file for full filenames
FILE_PAGES_INFO="${TMP_FLD}/pages-info.txt"				# for each page: page #; width in pt; height in pt
FILE_VALIDATION_LOG="${TMP_FLD}/pdf_validation.log"			# log file containing the results of the validation of the PDF/A file


# get the size of each pdf page (width / height) in pt (i.e. inch/72)
[ $VERBOSITY -ge $LOG_DEBUG ] && echo "Input file: Extracting size of each page (in pt)"
if [ "$USE_IMAGES" = "0" ]; then
        ! identify -format "%w %h\n" "$FILE_INPUT_PDF" > "$FILE_TMP" \
                && echo "Could not get size of PDF pages. Exiting..." && exit $EXIT_BAD_INPUT_FILE

        # removing empty lines (last one should be) and add page # before each line
        sed '/^$/d' "$FILE_TMP" | awk '{printf "%04d %s\n", NR, $0}' > "$FILE_PAGES_INFO"

        # Calculate the total number of pages.
        totalPages=`tail -n 1 "$FILE_PAGES_INFO" | cut -f1 -d" "`

        # process each page of the input pdf file
        parallel --progress --eta --gnu --no-notice --quote --keep-order $JOBS --halt-on-error 1 "$OCR_PAGE" "$FILE_INPUT_PDF" "{}" "$totalPages" "$TMP_FLD" \
                "$VERBOSITY" "$LANGUAGE" "$KEEP_TMP" "$PREPROCESS_DESKEW" "$PREPROCESS_CLEAN" "$PREPROCESS_CLEANTOPDF" "$OVERSAMPLING_DPI" \
                "$PDF_NOIMG" "$TESS_CFG_FILES" "$FORCE_OCR" "$SKIP_TEXT" :::: "$FILE_PAGES_INFO"
        ret_code="$?"
        [ "$ret_code" -ne 0 ] && exit $ret_code
else
        touch $FILE_INPUT_FILES
        # To get full path of images, we need to go back original path.
        cd "$CURRENT_PATH"
        for image in "${@}"; do
                echo `absolutePath "$image"` >> "$FILE_INPUT_FILES"
        done
        cd "`dirname $0`"

        parallel --progress --eta --gnu --keep-order $JOBS --halt-on-error 1 --no-run-if-empty 'identify -format "%w %h"' "{}" :::: "$FILE_INPUT_FILES" > "$FILE_TMP"
        ret_code="$?"
        [ "$ret_code" -ne 0 ] && exit $ret_code

        # removing empty lines (last one should be) and add page # before each line
        sed '/^$/d' "$FILE_TMP" | awk '{printf "%04d %s\n", NR, $0}' > "$FILE_PAGES_INFO"

        # Calculate the total number of pages.
        totalPages=`tail -n 1 "$FILE_PAGES_INFO" | cut -f1 -d" "`

        # process each page of the input pdf file
        parallel --progress --eta --gnu --no-notice --quote --keep-order $JOBS --halt-on-error 1 --xapply "$OCR_PAGE" "{1}" "{2}" "$totalPages" "$TMP_FLD" \
                "$VERBOSITY" "$LANGUAGE" "$KEEP_TMP" "$PREPROCESS_DESKEW" "$PREPROCESS_CLEAN" "$PREPROCESS_CLEANTOPDF" "$OVERSAMPLING_DPI" \
                "$PDF_NOIMG" "$TESS_CFG_FILES" "$FORCE_OCR" "$SKIP_TEXT" :::: "$FILE_INPUT_FILES" :::: "$FILE_PAGES_INFO"
        ret_code="$?"
        [ "$ret_code" -ne 0 ] && exit $ret_code
fi



# concatenate all pages and convert the pdf file to match PDF/A format
[ $VERBOSITY -ge $LOG_DEBUG ] && echo "Output file: Concatenating all pages to the final PDF/A file"
! gs -dQUIET -dPDFA -dBATCH -dNOPAUSE -dUseCIEColor \
	-sProcessColorModel=DeviceCMYK -sDEVICE=pdfwrite -sPDFACompatibilityPolicy=2 \
	-sOutputFile="$FILE_OUTPUT_PDFA" "${TMP_FLD}/"*ocred*.pdf 1> /dev/null 2> /dev/null \
	&& echo "Could not concatenate all pages to the final PDF/A file. Exiting..." && exit $EXIT_OTHER_ERROR

# validate generated pdf file (compliance to PDF/A)
[ $VERBOSITY -ge $LOG_DEBUG ] && echo "Output file: Checking compliance to PDF/A standard"
java -jar "$JHOVE" -c "$JHOVE_CFG" -m PDF-hul "$FILE_OUTPUT_PDFA" > "$FILE_VALIDATION_LOG"
grep -i "Status|Message" "$FILE_VALIDATION_LOG" # summary of the validation
[ $VERBOSITY -ge $LOG_DEBUG ] && echo "The full validation log is available here: \"$FILE_VALIDATION_LOG\""
# check the validation results
pdf_valid=1
grep -i 'ErrorMessage' "$FILE_VALIDATION_LOG" && pdf_valid=0
grep -i 'Status.*not valid' "$FILE_VALIDATION_LOG" && pdf_valid=0
grep -i 'Status.*Not well-formed' "$FILE_VALIDATION_LOG" && pdf_valid=0
! grep -i 'Profile:.*PDF/A-1' "$FILE_VALIDATION_LOG" > /dev/null && echo "PDF file profile is not PDF/A-1" && pdf_valid=0
[ "$pdf_valid" -ne 1 ] && echo "Output file: The generated PDF/A file is INVALID"
[ "$pdf_valid" -eq 1 ] && [ $VERBOSITY -ge $LOG_INFO ] && echo "Output file: The generated PDF/A file is VALID"



# delete temporary files
if [ "$KEEP_TMP" = "0" ]; then
	[ $VERBOSITY -ge $LOG_DEBUG ] && echo "Deleting temporary files"
	rm -r -f "${TMP_FLD}"
fi


END=`date +%s`
[ $VERBOSITY -ge $LOG_DEBUG ] && echo "Script took $(($END-$START)) seconds"


[ "$pdf_valid" -ne 1 ] && exit $EXIT_INVALID_OUPUT_PDFA || exit 0
