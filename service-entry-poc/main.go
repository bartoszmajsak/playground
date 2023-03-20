package main

import (
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"time"
)

func main() {
	serviceURLFlag := flag.String("service-url", "", "URL of the service to call")
	port := flag.String("port", "9988", "port of the service")
	flag.Parse()

	if *serviceURLFlag == "" {
		log.Fatal("service-url flag must be set")
	}

	serviceURL, err := url.Parse(*serviceURLFlag)

	if err != nil {
		log.Fatalf("failed parsing provided URL [%s]. Error: %s.", *serviceURLFlag, err.Error())
	}

	client := http.Client{
		Timeout: 1 * time.Second,
	}

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		log.Printf("Get called %s\n", r.Host)

		serviceReq := http.Request{
			Method: "GET",
			URL:    serviceURL,
			Header: http.Header{},
		}

		for name, values := range r.Header {
			for _, value := range values {
				log.Printf("%s: %s\n", name, value)
				serviceReq.Header.Add(name, value)
			}
		}

		resp, err := client.Do(&serviceReq)
		if err != nil {
			http.Error(w, fmt.Sprintf("Failed to get response: %v", err), http.StatusInternalServerError)
			return
		}
		defer resp.Body.Close()

		if _, err := io.Copy(w, resp.Body); err != nil {
			http.Error(w, fmt.Sprintf("Failed to copy response body: %v", err), http.StatusInternalServerError)
			return
		}
	})

	log.Printf("Starting echo server on port %s", *port)
	log.Fatal(http.ListenAndServe(":"+*port, nil))
}
