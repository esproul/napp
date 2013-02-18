if not needs_certificate() then
  redirect(http, "/")
end
http:write([=[<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en">
  <head>
    <meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
    <meta http-equiv="refresh" content="5">
    <link href="/c/s.css" rel="stylesheet" media="screen" type="text/css" />
    <link rel="shortcut icon" type="image/ico" href="/favicon.ico" />
  </head>
<body class="enterprise">
	<div id="masthead">
      <div id="header">
	    <span class="app-logo"> <a href="http://circonus.com/" title="Circonus Home">Circonus | Organization-wide Monitoring</a></span>
	  </div>
	</div>
	<div class="page">
	<div id="page-content" class="clear">
		<h1 class="waiting-copy">Awaiting provisioning by Circonus.</h1>
	</div>
	</div>
</body>
</html>]=])
