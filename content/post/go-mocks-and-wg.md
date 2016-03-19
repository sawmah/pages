+++
categories = ["default"]
date = "2016-03-19T16:44:17+03:00"
tags = ["go", "tests"]
title = "go mocks and wg"

+++
Этот пост задумывался как попытка разобраться с одним багом библиотеки gomocks, с которым я встретился во время написания тестов на конкурентный код - библиотека некоректно отрабатывала в случае false-кейсов, если тестируемый код работал в горутинах. Но, как минимум в master'е на текущий момент эта бага неактуальна, поэтому я просто напишу для себя заметку про gomock'и и waitgroup'ы.
Код описанный в данной заметке доступен по адресу https://github.com/soider/gomocks-tut.
<!--more-->
# Установка gomock и генерация моков:
```
go get github.com/golang/mock/gomock
go get github.com/golang/mock/mockgen
```
Первая команда устанавливает библиотеку gomock. Про вторую же чуть подробней дальше. Как и многие другие тулзы и утилиты в go-мире, gomock основан на кодогенерации, которая осуществляется с помощью утилиты mockgen. Mockgen генерирует моки, либо прочитывая переданный файл с исходниками, либо компилируя пакет и используя reflection'ы:
```
mockgen -package=mocks <packagename>  <symbols> # используя имя пакета и рефлексию, надо передать имя пакета и перечислить интерфейсы через запятую
mockgen -source=<path/to/source.go> -package=mocks # используя исходник
```
Параметром -package задается имя сгенерированного пакета, не исходного!
Кодогенерацию по имени пакета и символа удобно использовать для сторонних библиотек, можно не разбираться в структуре чужого пакета.

##### Тестируемый код #####

В этом примере я буду тестировать простую функцию, которая принимает слайс задач и раскидывает их по горутинам, синхронизация через sync.WaitGroup. Для обработки задач используется интерфейс ITaskProcesser с одним методом ProcessTask. Для ракидывания тасков по горутинам и синхронизацию используется функция-обертка DoTasks, которая прпринимает processer:

```
# tasks.go
package tasks

import "fmt"
import "github.com/soider/gomocks-tut/ifaces"
import "sync"
import "math/rand"
import "time"

type MyProcesser struct{}

func (p *MyProcesser) ProcessTask(task []int64) error {
	fmt.Println("Processing task", task)
	return nil
}

func DoTasks(tasks [][]int64, processer ifaces.ITaskProcesser) {
	rand.Seed(time.Now().UTC().UnixNano())
	var wg sync.WaitGroup
	wg.Add(len(tasks))
	for _, task := range tasks {
		go func(task []int64) {
			defer wg.Done()
			time.Sleep(time.Duration(rand.Intn(2)) * time.Second)
			processer.ProcessTask(task)
		}(task)
	}
	wg.Wait()

}

# ifaces/main.go
package ifaces

type ITaskProcesser interface {
	ProcessTask([]int64) error
}

# main.go

type MyProcesser struct{}

func (p *MyProcesser) ProcessTask(task []int64) error {
	fmt.Println("Processing task", task)
	return nil
}

func main() {
	tasks := [][]int64{
		[]int64{1, 2},
		[]int64{3, 4},
	}
	tasks.DoTasks(tasks, &MyProcesser{})
}
```
Что здесь происходит? DoTasks получает структуры processer, создает waitgroup, создает слайс с задачами. У созданной wg вызывается метод Add со значением равным длине слайса задач - после этого вызов .Wait будет ждать ровно столько вызовов .Done. Для того, чтобы убедиться, что вызовы действительно происходят конкурентно добален Sleep.
Запустим программу:
```
➜  gomocks-tut git:(master) ✗ go run main.go
Processing task [3 4]
Processing task [1 2]
➜  gomocks-tut git:(master) ✗ go run main.go
Processing task [1 2]
Processing task [3 4]
➜  gomocks-tut git:(master) ✗ go run main.go
Processing task [3 4]
Processing task [1 2]
```

Каждый следующий вызов даёт разный результат, то есть задачи обрабатываются действительно конкурентно.
DoTasks используется только как шедулер задач, реальную работу выполняет структура, удовлетворяющая интерфейсу ITaskProcesser.

В коде выше используется простая структура MyProcesser, которая просто печатает таск на консоль, но в реальном мире это мог быть поход в базу или во внешний сервис, поэтому для тестов необходимо использовать моки:
```
mockgen -package=mocks github.com/soider/gomocks-tut/ifaces  ITaskProcesser > mocks/main.go
```
Теперь сгенерированные моки будут доступны из пакета github.com/soider/gomocks-tut/mocks.

Простой тест для DoTasks будет выглядеть так:
```
# tasks/tasks_test.go

package tasks

import "testing"
import "github.com/golang/mock/gomock"
import "github.com/soider/gomocks-tut/mocks"

func TestDoTasksSchedulesEverythingCorrectly(t *testing.T) {
	mockCtrl := gomock.NewController(t) # 1 
	defer mockCtrl.Finish() # 2
	tasks := [][]int64{ # 3
		[]int64{1, 2},
		[]int64{3, 4},
	}
	taskProcessor := mocks.NewMockITaskProcesser(mockCtrl) #4
	taskProcessor.EXPECT().ProcessTask([]int64{1, 2}) # 5
	taskProcessor.EXPECT().ProcessTask([]int64{3, 4}) # 6

	DoTasks(tasks, taskProcessor)
}
```

В первую очередь, необходимо создать контроллер для моков (1). У контроллера обязательно должен быть вызван метод Finish, поэтому в (2) сразу шедулится вызов mockCtrl.Finish через механизм defer'ов.
В (4) создается структура, сгенерированная с помощью mockgen и эта структура удовлетворяет интерфейсу ITaskProcesser, поэтому её можно передать в функцию DoTasks!
В (5) и (6) с помощью EXPECT() описывается, какие ожидаются вызовы функций у замоканной структуры и с какими аргументами.
После этого вызывается DoTasks, на которую и написан этот тест.
Надо заметить, что даже если мы поменяем строки 5 и 6 местами, это не сломает тест - по умолчанию, EXPECT'у не важно, в каком порядке совершаться вызовы замоканных функций.

Запуск теста:
```
➜  tasks git:(master) ✗ go test ./...
ok  	github.com/soider/gomocks-tut/tasks	1.009s
➜  tasks git:(master) ✗ go test ./...
ok  	github.com/soider/gomocks-tut/tasks	1.010s
➜  tasks git:(master) ✗ go test ./...
ok  	github.com/soider/gomocks-tut/tasks	1.013s
➜  tasks git:(master) ✗ go test ./...
ok  	github.com/soider/gomocks-tut/tasks	1.010s
```

Как видно, тест срабатывает всегда, независимо от того, в каком порядке выполняются горутины.

Документация gomock: https://godoc.org/github.com/golang/mock/gomock
