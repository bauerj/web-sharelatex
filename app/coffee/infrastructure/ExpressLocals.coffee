logger = require 'logger-sharelatex'
fs = require 'fs'
crypto = require 'crypto'
Settings = require('settings-sharelatex')
SubscriptionFormatters = require('../Features/Subscription/SubscriptionFormatters')
querystring = require('querystring')
SystemMessageManager = require("../Features/SystemMessages/SystemMessageManager")
AuthenticationController = require("../Features/Authentication/AuthenticationController")
_ = require("underscore")
async = require("async")
Modules = require "./Modules"
Url = require "url"
PackageVersions = require "./PackageVersions"
htmlEncoder = new require("node-html-encoder").Encoder("numerical")
hashedFiles = {}
Path = require 'path'
Features = require "./Features"
Modules = require "./Modules"
moment = require 'moment'

jsPath =
	if Settings.useMinifiedJs
		"/minjs/"
	else
		"/js/"

ace = PackageVersions.lib('ace')
pdfjs = PackageVersions.lib('pdfjs')
fineuploader = PackageVersions.lib('fineuploader')

getFileContent = (filePath)->
	filePath = Path.join __dirname, "../../../", "public#{filePath}"
	exists = fs.existsSync filePath
	if exists
		content = fs.readFileSync filePath, "UTF-8"
		return content
	else
		logger.log filePath:filePath, "file does not exist for hashing"
		return ""

pathList = [
	"#{jsPath}libs/require.js"
	"#{jsPath}ide.js"
	"#{jsPath}main.js"
	"#{jsPath}libraries.js"
	"/stylesheets/style.css"
	"/stylesheets/light-style.css"
	"/stylesheets/ieee-style.css"
	"/stylesheets/sl-style.css"
].concat(Modules.moduleAssetFiles(jsPath))

if !Settings.useMinifiedJs
	logger.log "not using minified JS, not hashing static files"
else
	logger.log "Generating file hashes..."
	for path in pathList
		content = getFileContent(path)
		hash = crypto.createHash("md5").update(content).digest("hex")

		splitPath = path.split("/")
		filenameSplit = splitPath.pop().split(".")
		filenameSplit.splice(filenameSplit.length-1, 0, hash)
		splitPath.push(filenameSplit.join("."))

		hashPath = splitPath.join("/")
		hashedFiles[path] = hashPath

		fsHashPath = Path.join __dirname, "../../../", "public#{hashPath}"
		fs.writeFileSync(fsHashPath, content)


		logger.log "Finished hashing static content"

cdnAvailable = Settings.cdn?.web?.host?
darkCdnAvailable = Settings.cdn?.web?.darkHost?

module.exports = (app, webRouter, privateApiRouter, publicApiRouter)->
	webRouter.use (req, res, next)->
		res.locals.session = req.session
		next()

	addSetContentDisposition = (req, res, next) ->
		res.setContentDisposition = (type, opts) ->
			directives = for k, v of opts
				"#{k}=\"#{encodeURIComponent(v)}\""
			contentDispositionValue = "#{type}; #{directives.join('; ')}"
			res.setHeader(
				'Content-Disposition',
				contentDispositionValue
			)
		next()
	webRouter.use addSetContentDisposition
	privateApiRouter.use addSetContentDisposition
	publicApiRouter.use addSetContentDisposition

	webRouter.use (req, res, next)->
		req.externalAuthenticationSystemUsed = Features.externalAuthenticationSystemUsed
		res.locals.externalAuthenticationSystemUsed = Features.externalAuthenticationSystemUsed
		req.hasFeature = res.locals.hasFeature = Features.hasFeature
		res.locals.userIsFromOLv1 = (user) ->
			user.overleaf?.id?
		res.locals.userIsFromSL = (user) ->
			!user.overleaf?.id?
		next()

	webRouter.use (req, res, next)->

		cdnBlocked = req.query.nocdn == 'true' or req.session.cdnBlocked
		user_id = AuthenticationController.getLoggedInUserId(req)

		if cdnBlocked and !req.session.cdnBlocked?
			logger.log user_id:user_id, ip:req?.ip, "cdnBlocked for user, not using it and turning it off for future requets"
			req.session.cdnBlocked = true

		isDark = req.headers?.host?.slice(0,7)?.toLowerCase().indexOf("dark") != -1
		isSmoke = req.headers?.host?.slice(0,5)?.toLowerCase() == "smoke"
		isLive = !isDark and !isSmoke

		if cdnAvailable and isLive and !cdnBlocked
			staticFilesBase = Settings.cdn?.web?.host
		else if darkCdnAvailable and isDark
			staticFilesBase = Settings.cdn?.web?.darkHost
		else
			staticFilesBase = ""

		res.locals.jsPath = jsPath
		res.locals.fullJsPath = Url.resolve(staticFilesBase, jsPath)
		res.locals.lib = PackageVersions.lib

		res.locals.moment = moment

		res.locals.buildJsPath = (jsFile, opts = {})->
			path = Path.join(jsPath, jsFile)

			if opts.hashedPath && hashedFiles[path]?
				path = hashedFiles[path]

			if !opts.qs?
				opts.qs = {}

			if opts.cdn != false
				path = Url.resolve(staticFilesBase, path)

			qs = querystring.stringify(opts.qs)

			if opts.removeExtension == true
				path = path.slice(0,-3)

			if qs? and qs.length > 0
				path = path + "?" + qs
			return path

		res.locals.buildWebpackPath = (jsFile, opts = {}) ->
			if Settings.webpack? and !Settings.useMinifiedJs
				path = Path.join(jsPath, jsFile)
				if opts.removeExtension == true
					path = path.slice(0,-3)
				return "#{Settings.webpack.url}/public#{path}"
			else
				return res.locals.buildJsPath(jsFile, opts)


		IEEE_BRAND_ID = 15
		res.locals.isIEEE = (brandVariation) ->
			brandVariation?.brand_id == IEEE_BRAND_ID

		_buildCssFileName = (themeModifier) ->
			return "/" + Settings.brandPrefix + (if themeModifier then themeModifier else "") + "style.css"

		res.locals.getCssThemeModifier = (userSettings, brandVariation) ->
			# Themes only exist in OL v2
			if Settings.overleaf?
				# The IEEE theme takes precedence over the user personal setting, i.e. a user with
				# a theme setting of "light" will still get the IEE theme in IEEE branded projects.
				if res.locals.isIEEE(brandVariation)
					themeModifier = "ieee-"
				else if userSettings?.overallTheme?
					themeModifier = userSettings.overallTheme
			return themeModifier

		res.locals.buildCssPath = (themeModifier, buildOpts) ->
			cssFileName = _buildCssFileName themeModifier
			path = Path.join("/stylesheets/", cssFileName)
			if buildOpts?.hashedPath && hashedFiles[path]?
				hashedPath = hashedFiles[path]
				return Url.resolve(staticFilesBase, hashedPath)
			return Url.resolve(staticFilesBase, path)

		res.locals.buildImgPath = (imgFile)->
			path = Path.join("/img/", imgFile)
			return Url.resolve(staticFilesBase, path)

		res.locals.mathJaxPath = res.locals.buildJsPath(
			'libs/mathjax/MathJax.js',
			{cdn:false, qs:{config:'TeX-AMS_HTML,Safe'}}
		)

		next()

	webRouter.use (req, res, next)->
		res.locals.settings = Settings
		next()

	webRouter.use (req, res, next)->
		res.locals.translate = (key, vars = {}, htmlEncode = false) ->
			vars.appName = Settings.appName
			str = req.i18n.translate(key, vars)
			if htmlEncode then htmlEncoder.htmlEncode(str) else str
		# Don't include the query string parameters, otherwise Google
		# treats ?nocdn=true as the canonical version
		res.locals.currentUrl = Url.parse(req.originalUrl).pathname
		res.locals.capitalize = (string) ->
			return "" if string.length == 0
			return string.charAt(0).toUpperCase() + string.slice(1)
		next()

	webRouter.use (req, res, next)->
		res.locals.getSiteHost = ->
			Settings.siteUrl.substring(Settings.siteUrl.indexOf("//")+2)
		next()

	webRouter.use (req, res, next) ->
		res.locals.getUserEmail = ->
			user = AuthenticationController.getSessionUser(req)
			email = user?.email or ""
			return email
		next()

	webRouter.use (req, res, next) ->
		res.locals.StringHelper = require('../Features/Helpers/StringHelper')
		next()

	webRouter.use (req, res, next)->
		res.locals.formatProjectPublicAccessLevel = (privilegeLevel)->
			formatedPrivileges = private:"Private", readOnly:"Public: Read Only", readAndWrite:"Public: Read and Write"
			return formatedPrivileges[privilegeLevel] || "Private"
		next()

	webRouter.use (req, res, next)->
		res.locals.buildReferalUrl = (referal_medium) ->
			url = Settings.siteUrl
			currentUser = AuthenticationController.getSessionUser(req)
			if currentUser? and currentUser?.referal_id?
				url+="?r=#{currentUser.referal_id}&rm=#{referal_medium}&rs=b" # Referal source = bonus
			return url
		res.locals.getReferalId = ->
			currentUser = AuthenticationController.getSessionUser(req)
			if currentUser? and currentUser?.referal_id?
				return currentUser.referal_id
		res.locals.getReferalTagLine = ->
			tagLines = [
				"Roar!"
				"Shout about us!"
				"Please recommend us"
				"Tell the world!"
				"Thanks for using ShareLaTeX"
			]
			return tagLines[Math.floor(Math.random()*tagLines.length)]
		res.locals.getRedirAsQueryString = ->
			if req.query.redir?
				return "?#{querystring.stringify({redir:req.query.redir})}"
			return ""

		res.locals.getLoggedInUserId = ->
			return AuthenticationController.getLoggedInUserId(req)
		res.locals.isUserLoggedIn = ->
			return AuthenticationController.isUserLoggedIn(req)
		res.locals.getSessionUser = ->
			return AuthenticationController.getSessionUser(req)

		next()

	webRouter.use (req, res, next) ->
		res.locals.csrfToken = req?.csrfToken()
		next()

	webRouter.use (req, res, next) ->
		res.locals.getReqQueryParam = (field)->
			return req.query?[field]
		next()

	webRouter.use (req, res, next)->
		res.locals.formatPrice = SubscriptionFormatters.formatPrice
		next()

	webRouter.use (req, res, next)->
		currentUser = AuthenticationController.getSessionUser(req)
		if currentUser?
			res.locals.user =
				email: currentUser.email
				first_name: currentUser.first_name
				last_name: currentUser.last_name
			if req.session.justRegistered
				res.locals.justRegistered = true
				delete req.session.justRegistered
			if req.session.justLoggedIn
				res.locals.justLoggedIn = true
				delete req.session.justLoggedIn
		res.locals.gaToken       = Settings.analytics?.ga?.token
		res.locals.tenderUrl     = Settings.tenderUrl
		res.locals.sentrySrc     = Settings.sentry?.src
		res.locals.sentryPublicDSN = Settings.sentry?.publicDSN
		next()

	webRouter.use (req, res, next) ->
		if req.query? and req.query.scribtex_path?
			res.locals.lookingForScribtex = true
			res.locals.scribtexPath = req.query.scribtex_path
		next()

	webRouter.use (req, res, next) ->
		# Clone the nav settings so they can be modified for each request
		res.locals.nav = {}
		for key, value of Settings.nav
			res.locals.nav[key] = _.clone(Settings.nav[key])
		res.locals.templates = Settings.templateLinks
		if res.locals.nav.header
			console.error {}, "The `nav.header` setting is no longer supported, use `nav.header_extras` instead"
		next()

	webRouter.use (req, res, next) ->
		SystemMessageManager.getMessages (error, messages = []) ->
			res.locals.systemMessages = messages
			next()

	webRouter.use (req, res, next)->
		res.locals.query = req.query
		next()

	webRouter.use (req, res, next)->
		subdomain = _.find Settings.i18n.subdomainLang, (subdomain)->
			subdomain.lngCode == req.showUserOtherLng and !subdomain.hide
		res.locals.recomendSubdomain = subdomain
		res.locals.currentLngCode = req.lng
		next()

	webRouter.use (req, res, next) ->
		if Settings.reloadModuleViewsOnEachRequest
			Modules.loadViewIncludes()
		res.locals.moduleIncludes = Modules.moduleIncludes
		res.locals.moduleIncludesAvailable = Modules.moduleIncludesAvailable
		next()

	webRouter.use (req, res, next) ->
		isSl = (Settings.brandPrefix == 'sl-')
		res.locals.uiConfig =
			defaultResizerSizeOpen     : if isSl then 24 else 7
			defaultResizerSizeClosed   : if isSl then 24 else 7
			eastResizerCursor          : if isSl then null else "ew-resize"
			westResizerCursor          : if isSl then null else "ew-resize"
			chatResizerSizeOpen        : if isSl then 12 else 7
			chatResizerSizeClosed      : 0
			chatMessageBorderSaturation: if isSl then "70%" else "85%"
			chatMessageBorderLightness : if isSl then "70%" else "40%"
			chatMessageBgSaturation    : if isSl then "60%" else "85%"
			chatMessageBgLightness     : if isSl then "97%" else "40%"
			defaultFontFamily          : if isSl then 'monaco' else 'lucida'
			defaultLineHeight          : if isSl then 'compact' else 'normal'
			renderAnnouncements        : isSl
		next()

	webRouter.use (req, res, next) ->
		#TODO
		if Settings.overleaf?
			res.locals.overallThemes = [
				{ name: "Default", val: "",       path: res.locals.buildCssPath(null,     { hashedPath: true }) }
				{ name: "Light",   val: "light-", path: res.locals.buildCssPath("light-", { hashedPath: true }) }
			]
		next()

	webRouter.use (req, res, next) ->
		res.locals.ExposedSettings =
			isOverleaf: Settings.overleaf?
			appName: Settings.appName
			siteUrl: Settings.siteUrl
			recaptchaSiteKeyV3: Settings.recaptcha?.siteKeyV3
		next()
