package middleware

import (
	"fmt"
	"net/http"
	"runtime/debug"

	"github.com/QuantumNous/new-api/common"
	"github.com/gin-gonic/gin"
)

func RelayPanicRecover() gin.HandlerFunc {
	return func(c *gin.Context) {
		defer func() {
			if err := recover(); err != nil {
				common.SysLog(fmt.Sprintf("panic detected: %v", err))
				common.SysLog(fmt.Sprintf("stacktrace from panic: %s", string(debug.Stack())))
				c.JSON(http.StatusInternalServerError, gin.H{
					"error": gin.H{
						"message": fmt.Sprintf("Internal server error: %v. Please contact support.", err),
						"type":    "internal_error",
					},
				})
				c.Abort()
			}
		}()
		c.Next()
	}
}
