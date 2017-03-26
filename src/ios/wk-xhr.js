((function wk_xhr() {
    try {
        const OriginalXMLHttpRequestPrototypeOpen = window.XMLHttpRequest.prototype.open;
        const OriginalXMLHttpRequestPrototypeSend = window.XMLHttpRequest.prototype.send;
        window.XMLHttpRequest.prototype.open = function() {
            // open a xhr request, record url here
            const args = arguments;
            const method = args.length >= 1 ? args[0]: null;
            if (method === 'GET') {
                return OriginalXMLHttpRequestPrototypeOpen.apply(this, arguments);
            }
            const url = args.length >= 2 ? args[1] : null;
            if (url) {
                // keep the url in xhr, so it can be
                // redirected in proxy server later
                this['__wkwebview_symbol__url'] = url;
                // set the url to proxy server
                args[1] = '${proxyurl}/api';
            }
            return OriginalXMLHttpRequestPrototypeOpen.apply(this, arguments);
        }

        window.XMLHttpRequest.prototype.send = function() {
            // set request header of the original url
            const originalUrl = this['__wkwebview_symbol__url'];
            if (originalUrl) {
                this.withCredentials = false;
                this.setRequestHeader('X-original-url', originalUrl);
                this.setRequestHeader('X-proxy-secret', '${secret}');
            }
            return OriginalXMLHttpRequestPrototypeSend.apply(this, arguments);
        }
    } catch (err) {
        console.log('error to patch XMLHttpRequest prototype', err);
    }
})());